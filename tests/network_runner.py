"""Run isolated transport suites or the actual-scene game replication suite."""
from __future__ import annotations

import argparse
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", choices=("local", "remote", "certificate", "game", "expiry", "commands"))
    parser.add_argument("--godot", type=Path, default=Path(r"C:/Program Files/Godot/Godot.exe"))
    args = parser.parse_args()
    local = ROOT / ".local/network"
    stage = ROOT if args.suite in ("game", "expiry", "commands") else local / ("suite-" + args.suite)
    stage.mkdir(parents=True, exist_ok=True)
    files = ["scripts/network/network_protocol.gd", "scripts/network/relay_client.gd", "scripts/network/relay_trust.crt"]
    script = {"local": "network_relay_test.gd", "remote": "network_remote_test.gd", "certificate": "network_certificate_test.gd", "game": "network_game_replication_test.gd", "expiry": "network_game_expiry_test.gd", "commands": "network_command_validation_test.gd"}[args.suite]
    files.append("tests/" + script)
    if args.suite == "local":
        files.append("server/relay_server.gd")
        spec = importlib.util.spec_from_file_location("relay_deploy", ROOT / "tools/deploy_relay.py")
        deploy = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(deploy)
        engine = deploy.runtime("win64.exe")
    elif args.suite not in ("game", "expiry", "commands"):
        files.append(".local/network/endpoint.json")
        engine = args.godot
    else:
        engine = args.godot
    if (ROOT / "data/content_manifest.json").exists():
        files.append("data/content_manifest.json")
    if args.suite not in ("game", "expiry", "commands"):
        for relative in files:
            destination = stage / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, destination)
        shutil.copy2(ROOT / "server/relay_project.godot", stage / "project.godot")
    out_path = local / (args.suite + ".stdout.log")
    err_path = local / (args.suite + ".stderr.log")
    command = [str(engine), "--headless", "--log-file", str(local / (args.suite + ".engine.log")), "--path", str(stage), "--script", "res://tests/" + script]
    with out_path.open("wb") as out, err_path.open("wb") as err:
        process = subprocess.Popen(command, stdout=out, stderr=err, creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            code = process.wait(timeout=90)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
            print("NETWORK_SUITE_TIMEOUT " + args.suite)
            return 1
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
    stdout = out_path.read_text(encoding="utf-8", errors="replace")
    stderr = err_path.read_text(encoding="utf-8", errors="replace")
    # Emit only intentionally sanitized summaries, never raw engine endpoint diagnostics.
    for line in stdout.splitlines():
        if line.startswith(("NETWORK_RESULTS ", "NETWORK_REMOTE_RESULTS ", "NETWORK_REMOTE_METRICS ", "NETWORK_CERTIFICATE_RESULTS ", "NETWORK_GAME_RESULTS ", "NETWORK_GAME_METRICS ", "NETWORK_GAME_QUANTIZATION_METRICS ", "NETWORK_GAME_EXPIRY_RESULTS ", "NETWORK_COMMAND_VALIDATION_RESULTS ")):
            print(line)
    if args.suite != "certificate" and stderr.strip():
        print("NETWORK_SUITE_HAS_STDERR " + args.suite)
        return 1
    if args.suite == "certificate":
        allowed = {"ERROR: TLS handshake error: -9984"}  # MBEDTLS_ERR_X509_CERT_VERIFY_FAILED.
        # An invalid certificate is expected to report a native TLS rejection. Every
        # unexpected script error still fails, and the assertion also checks recovery.
        native_errors = [line.strip() for line in stderr.splitlines() if line.startswith("ERROR:")]
        if "SCRIPT ERROR" in stderr or any(line not in allowed for line in native_errors) or (stderr.strip() and not native_errors):
            print("NETWORK_CERTIFICATE_UNEXPECTED_STDERR")
            return 1
    print("NETWORK_SUITE_EXIT " + args.suite + " " + str(code))
    return code


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print("NETWORK_RUNNER_FAILED type=" + type(error).__name__, file=sys.stderr)
        raise SystemExit(1)
