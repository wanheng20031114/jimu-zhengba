"""Four independent headless main scenes over a local or deployed DTLS relay."""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time
import uuid

from network_udp_impairment import ImpairedRelay

ROOT = Path(__file__).resolve().parents[1]
LOCAL = ROOT / ".local/network"


def engine_diagnostics(path: Path, impaired: bool) -> tuple[bool, int]:
    stderr = path.read_text(encoding="utf-8", errors="replace")
    if not stderr.strip():
        return False, 0
    native_errors = [line.strip() for line in stderr.splitlines() if line.startswith("ERROR:")]
    # DTLS can reject reordered handshake messages before ENet exists. Bounded
    # connection retry must recover; no certificate verification failure or
    # script error is exempted. Keep this diagnostic count in the final report.
    allowed = {"ERROR: TLS handshake error: -30464"} if impaired else set()
    unexpected = "SCRIPT ERROR" in stderr or not native_errors or any(line not in allowed for line in native_errors)
    return unexpected, sum(line in allowed for line in native_errors)


def load_deploy():
    spec = importlib.util.spec_from_file_location("relay_deploy", ROOT / "tools/deploy_relay.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def local_server(directory: Path, children: list, handles: list) -> dict:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "ashen-crown-relay")])
    now = datetime.now(timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(now - timedelta(minutes=5))
            .not_valid_after(now + timedelta(days=1))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName("ashen-crown-relay")]), critical=False)
            .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True).sign(key, hashes.SHA256()))
    key_path = directory / "test-private.key"
    cert_path = directory / "test-trust.crt"
    key_path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption()))
    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    stage = directory / "relay-project"
    for relative in ("server/relay_main.gd", "server/relay_server.gd", "server/relay.tscn", "scripts/network/network_protocol.gd"):
        destination = stage / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / relative, destination)
    manifest = ROOT / "data/content_manifest.json"
    if manifest.exists():
        (stage / "data").mkdir(exist_ok=True)
        shutil.copy2(manifest, stage / "data/content_manifest.json")
    shutil.copy2(ROOT / "server/relay_project.godot", stage / "project.godot")
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    config = directory / "relay.cfg"
    config.write_text('[relay]\nbind="127.0.0.1"\nport=%d\nmax_rooms=1\nmax_humans=4\n[tls]\nprivate_key=%s\ncertificate=%s\n'
                      % (port, json.dumps(key_path.as_posix()), json.dumps(cert_path.as_posix())), encoding="utf-8")
    out = (directory / "relay.stdout.log").open("wb")
    err = (directory / "relay.stderr.log").open("wb")
    handles.extend((out, err))
    environment = os.environ.copy()
    environment["ASHEN_RELAY_CONFIG"] = str(config)
    runtime = load_deploy().runtime("win64.exe")
    process = subprocess.Popen([str(runtime), "--headless", "--path", str(stage), "--script", "res://server/relay_main.gd"],
                               env=environment, stdout=out, stderr=err, creationflags=subprocess.CREATE_NO_WINDOW)
    children.append(process)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if "ASHEN_RELAY_READY" in (directory / "relay.stdout.log").read_text(encoding="utf-8", errors="replace"):
            return {"address": "127.0.0.1", "port": port, "certificate": cert_path.as_posix()}
        if process.poll() is not None:
            raise RuntimeError("local_relay_failed")
        time.sleep(0.1)
    raise TimeoutError("local_relay_ready")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=("local", "remote", "impaired"))
    parser.add_argument("--seed", type=int, default=24571)
    parser.add_argument("--loss", type=float, choices=(0.03, 0.04, 0.05), default=0.04)
    parser.add_argument("--steady-seconds", type=float, default=15)
    # Launch the engine itself: killing the small Windows console wrapper on a
    # timeout can leave its child engine alive after this runner has returned.
    parser.add_argument("--godot", type=Path, default=Path("C:/Program Files/Godot/Godot.exe"))
    args = parser.parse_args()
    if not 0 <= args.steady_seconds <= 30:
        parser.error("--steady-seconds must be between 0 and 30")
    directory = LOCAL / ("live-" + args.target + "-" + uuid.uuid4().hex[:8])
    directory.mkdir(parents=True)
    children: list[subprocess.Popen] = []
    peers: list[subprocess.Popen] = []
    handles = []
    failed: list[str] = []
    expected_dtls_diagnostics = 0
    impairment: ImpairedRelay | None = None
    try:
        endpoint = local_server(directory, children, handles) if args.target != "remote" else json.loads((LOCAL / "endpoint.json").read_text(encoding="utf-8"))
        (directory / "endpoint.json").write_text(json.dumps(endpoint), encoding="utf-8")
        if args.target == "impaired":
            impairment = ImpairedRelay((endpoint["address"], endpoint["port"]), seed=args.seed, loss=args.loss).start()
            for index, port in enumerate(impairment.ports):
                # The public certificate still authenticates the actual relay;
                # forwarding never parses, decrypts, or substitutes DTLS records.
                record = dict(endpoint, address="127.0.0.1", port=port, impaired=True, steady_seconds=args.steady_seconds)
                (directory / ("endpoint-%d.json" % index)).write_text(json.dumps(record), encoding="utf-8")
        for index in range(4):
            out = (directory / ("peer-%d.stdout.log" % index)).open("wb")
            err = (directory / ("peer-%d.stderr.log" % index)).open("wb")
            handles.extend((out, err))
            command = [str(args.godot), "--headless", "--path", str(ROOT), "--script", "res://tests/network_game_live.gd", "--",
                       "--live-dir=" + directory.as_posix(), "--peer-index=" + str(index)]
            process = subprocess.Popen(command, stdout=out, stderr=err, creationflags=subprocess.CREATE_NO_WINDOW)
            children.append(process)
            peers.append(process)
            time.sleep(0.35)
        deadline = time.monotonic() + 150
        last_phase = ""
        while time.monotonic() < deadline and any(process.poll() is None for process in peers):
            phase_path = directory / "phase.json"
            if phase_path.exists():
                try:
                    phase = json.loads(phase_path.read_text(encoding="utf-8")).get("stage", "")
                    if phase != last_phase:
                        last_phase = phase
                        print("NETWORK_GAME_LIVE_PHASE " + phase, flush=True)
                except (ValueError, OSError):
                    pass
            time.sleep(0.25)
        results = []
        for index, process in enumerate(peers):
            if process.poll() is None:
                failed.append("peer_%d_timeout" % index)
            elif process.returncode != 0:
                failed.append("peer_%d_exit_%d" % (index, process.returncode))
            path = directory / ("result-%d.json" % index)
            if path.exists():
                result = json.loads(path.read_text(encoding="utf-8"))
                results.append(result)
                if result["failures"]:
                    failed.append("peer_%d_assertions" % index)
            else:
                failed.append("peer_%d_missing_result" % index)
            unexpected, expected = engine_diagnostics(directory / ("peer-%d.stderr.log" % index), args.target == "impaired")
            expected_dtls_diagnostics += expected
            if unexpected:
                failed.append("peer_%d_stderr" % index)
        if args.target != "remote":
            unexpected, expected = engine_diagnostics(directory / "relay.stderr.log", args.target == "impaired")
            expected_dtls_diagnostics += expected
            if unexpected:
                failed.append("local_relay_stderr")
        report = {"target": args.target, "failures": failed, "peers": results, "log_directory": directory.name,
                  "expected_dtls_reorder_diagnostics": expected_dtls_diagnostics}
        if impairment is not None:
            report["impairment"] = impairment.close()
            impairment = None
            statistics = report["impairment"]
            if statistics["error"]:
                failed.append("impairment_thread_error")
            if sum(item["dropped"] for item in statistics["directions"]) == 0:
                failed.append("impairment_did_not_drop_packets")
            if sum(item["out_of_order_deliveries"] for item in statistics["directions"]) == 0:
                failed.append("impairment_did_not_reorder_packets")
        (directory / "summary.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        print("NETWORK_GAME_LIVE_RESULTS " + json.dumps(report, ensure_ascii=False))
        return 1 if failed else 0
    finally:
        for process in children:
            if process.poll() is None:
                process.terminate()
        for process in children:
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=8)
        for handle in handles:
            handle.close()
        if impairment is not None:
            impairment.close()
        private_key = directory / "test-private.key"
        if private_key.exists():
            private_key.unlink()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print("NETWORK_GAME_LIVE_FAILED type=" + type(error).__name__, file=sys.stderr)
        raise SystemExit(1)
