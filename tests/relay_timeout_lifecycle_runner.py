"""Run application-heartbeat expiry in an isolated native DTLS project."""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import time
import uuid

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

ROOT = Path(__file__).resolve().parents[1]


def native_runtime() -> Path:
    spec = importlib.util.spec_from_file_location("timeout_relay_runtime", ROOT / "tools/deploy_relay.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.runtime("win64.exe")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--disconnect", choices=("current", "immediate"), default="current",
                        help="immediate restores the old timeout only in the isolated server for an A/B experiment")
    args = parser.parse_args()
    stage = ROOT / ".local/network" / ("timeout-lifecycle-" + uuid.uuid4().hex[:8])
    stage.mkdir(parents=True)
    for relative in ("server/relay_server.gd", "scripts/network/network_protocol.gd",
                     "data/content_manifest.json", "tests/relay_timeout_lifecycle_test.gd"):
        target = stage / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / relative, target)
    if args.disconnect == "immediate":
        copied_server = stage / "server/relay_server.gd"
        original = copied_server.read_text(encoding="utf-8")
        if original.count("peer.peer_disconnect()") != 1:
            raise RuntimeError("isolated timeout replacement no longer matches the server")
        copied_server.write_text(original.replace("peer.peer_disconnect()", "peer.peer_disconnect_now()"), encoding="utf-8")
    shutil.copy2(ROOT / "server/relay_project.godot", stage / "project.godot")
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "ashen-crown-relay")])
    now = datetime.now(timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - timedelta(minutes=5)).not_valid_after(now + timedelta(days=1))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName("ashen-crown-relay")]), critical=False)
            .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
            .sign(key, hashes.SHA256()))
    (stage / "test-private.key").write_bytes(key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption()))
    (stage / "test-trust.crt").write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    command = [str(native_runtime()), "--headless", "--audio-driver", "Dummy", "--path", str(stage),
               "--log-file", str(stage / "engine.log"), "--script", "res://tests/relay_timeout_lifecycle_test.gd"]
    started = time.monotonic()
    with (stage / "stdout.log").open("wb") as out, (stage / "stderr.log").open("wb") as err:
        process = subprocess.Popen(command, stdout=out, stderr=err, creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            code = process.wait(timeout=75)
        except subprocess.TimeoutExpired:
            code = 124
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
    stdout = (stage / "stdout.log").read_text(encoding="utf-8", errors="replace")
    stderr = (stage / "stderr.log").read_text(encoding="utf-8", errors="replace")
    for line in stdout.splitlines():
        if line.startswith(("RELAY_TIMEOUT_PHASE ", "RELAY_TIMEOUT_RESULTS ")):
            print(line)
    summary = {"exit_code": code, "pid": process.pid, "process_exited": process.poll() is not None,
               "disconnect": args.disconnect,
               "elapsed_seconds": round(time.monotonic() - started, 3),
               "stderr_empty": not stderr.strip(), "result_present": "RELAY_TIMEOUT_RESULTS " in stdout,
               "directory": str(stage)}
    (stage / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print("RELAY_TIMEOUT_RUNNER " + json.dumps(summary))
    return 0 if code == 0 and not stderr.strip() and summary["result_present"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
