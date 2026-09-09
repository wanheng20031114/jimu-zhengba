"""Bounded native tests for the range and recovery upgrades, with owned log files."""
from pathlib import Path
import argparse
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--benchmark", action="store_true")
    parser.add_argument("--bot", action="store_true")
    args = parser.parse_args()
    name = "bot_strategy_test" if args.bot else ("recovery_microbenchmark" if args.benchmark else "special_upgrades_test")
    directory = ROOT / ".local" / "special-upgrades0100"
    directory.mkdir(parents=True, exist_ok=True)
    stdout_path = directory / (name + ".stdout.log")
    stderr_path = directory / (name + ".stderr.log")
    command = [r"C:/Program Files/Godot/Godot.exe", "--headless", "--path", str(ROOT),
               "--log-file", str(directory / (name + ".engine.log")), "--script", f"res://tests/{name}.gd"]
    with stdout_path.open("wb") as out, stderr_path.open("wb") as err:
        process = subprocess.Popen(command, stdout=out, stderr=err, creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            code = process.wait(timeout=75)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
            code = 3
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
    stdout = stdout_path.read_text(encoding="utf-8", errors="replace")
    stderr = stderr_path.read_text(encoding="utf-8", errors="replace")
    for line in stdout.splitlines():
        if line.startswith(("SPECIAL_UPGRADES_RESULTS ", "RECOVERY_MICROBENCHMARK_RESULTS ", "BOT_STRATEGY ")):
            print(line)
    if stderr.strip():
        print(stderr)
    print(json.dumps({"suite": name, "exit_code": code, "stderr": bool(stderr.strip()), "pid_exited": process.poll() is not None}))
    return code if code else int(bool(stderr.strip()))


if __name__ == "__main__":
    raise SystemExit(main())
