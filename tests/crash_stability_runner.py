"""Bounded native Windows/Vulkan/WASAPI stability run, with isolated log files."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import time


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    directory = root / ".local" / "crash-2026-09-10"
    directory.mkdir(parents=True, exist_ok=True)
    stdout_path = directory / "stability-vulkan-stdout.log"
    stderr_path = directory / "stability-vulkan-stderr.log"
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = subprocess.SW_HIDE
    arguments = [
        "C:/Program Files/Godot/Godot.exe", "--path", str(root),
        "--rendering-driver", "vulkan", "--resolution", "960x540", "--position", "0,0",
        "--log-file", str(directory / "stability-vulkan-engine.log"),
        "--script", "res://tests/crash_stability_test.gd",
    ]
    started = time.monotonic()
    timed_out = False
    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        process = subprocess.Popen(
            arguments, cwd=root, stdout=stdout, stderr=stderr,
            startupinfo=startup, creationflags=subprocess.CREATE_NO_WINDOW,
        )
        print(f"CRASH_STABILITY_PROCESS {process.pid}", flush=True)
        try:
            while process.poll() is None:
                remaining = 175.0 - (time.monotonic() - started)
                if remaining <= 0:
                    timed_out = True
                    break
                try:
                    process.wait(timeout=min(1.0, remaining))
                except subprocess.TimeoutExpired:
                    pass
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)
    stdout = stdout_path.read_text(encoding="utf-8", errors="replace")
    stderr = stderr_path.read_text(encoding="utf-8", errors="replace")
    result_lines = [line for line in stdout.splitlines() if line.startswith("CRASH_STABILITY_RESULT ")]
    result = json.loads(result_lines[-1].split(" ", 1)[1]) if result_lines else {}
    clean = not stderr.strip() and not any(
        marker in stdout for marker in ("SCRIPT ERROR", "Program crashed", "CRASH_STABILITY_FAIL", "CRASH_STABILITY_TIMEOUT")
    )
    passed = process.returncode == 0 and not timed_out and clean and result.get("ok") is True
    report = {
        "passed": passed, "pid": process.pid, "exit_code": process.returncode,
        "wall_seconds": round(time.monotonic() - started, 2), "timed_out": timed_out,
        "stderr_empty": not stderr.strip(), "result": result,
    }
    (directory / "stability-vulkan-runner.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False), flush=True)
    if not passed:
        print(stdout[-7000:], flush=True)
        print(stderr[-7000:], flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
