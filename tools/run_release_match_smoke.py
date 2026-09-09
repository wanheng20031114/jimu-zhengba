"""Exercise the packaged Session/main-scene victory flow; only terminate this runner's child."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path, help="AshenCrown.exe; or Godot_console.exe with --project")
    parser.add_argument("--project", type=Path, help="Source validation only: Godot project directory")
    parser.add_argument("--fast", action="store_true", help="10x wall-clock speed; same 1/30-second simulation delta")
    parser.add_argument("--headless", action="store_true", help="Use native Dummy renderer instead of a visible game window")
    parser.add_argument("--diagnose", action="store_true", help="Observe only 120 simulation seconds; always fails acceptance")
    parser.add_argument("--output", type=Path, default=Path("artifacts/release-match"), help="Log/report filename prefix")
    parser.add_argument("--timeout", type=float, help="Wall-clock seconds; default 330 fast or 1530 normal")
    args = parser.parse_args()
    executable = args.executable.resolve(strict=True)
    prefix = args.output.resolve()
    prefix.parent.mkdir(parents=True, exist_ok=True)
    stdout_path = prefix.parent / (prefix.name + ".stdout.log")
    stderr_path = prefix.parent / (prefix.name + ".stderr.log")
    report_path = prefix.parent / (prefix.name + ".json")
    command = [str(executable), "--audio-driver", "Dummy", "--log-file", str(prefix.parent / (prefix.name + ".engine.log"))]
    if args.project:
        command += ["--path", str(args.project.resolve(strict=True))]
    if args.headless:
        command += ["--headless"]
    command += ["--", "--match-smoke"]
    if args.fast:
        command += ["--match-smoke-fast"]
    if args.diagnose:
        command += ["--match-smoke-diagnose"]
    timeout = args.timeout if args.timeout is not None else (330.0 if args.fast else 1530.0)
    if timeout <= 0:
        parser.error("--timeout must be positive")
    started = time.monotonic()
    timed_out = False
    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        process = subprocess.Popen(
            command, cwd=str(args.project.resolve() if args.project else executable.parent),
            stdout=stdout, stderr=stderr,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        )
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
        finally:
            # Never enumerate or terminate the user's editor or another test's process.
            if process.poll() is None:
                process.kill()
            process.wait()
    stdout_text = stdout_path.read_text(encoding="utf-8-sig", errors="replace")
    stderr_text = stderr_path.read_text(encoding="utf-8-sig", errors="replace")
    lines = [line.removeprefix("MATCH_SMOKE_RESULT ") for line in stdout_text.splitlines() if line.startswith("MATCH_SMOKE_RESULT ")]
    result = None
    parse_error = ""
    if len(lines) == 1:
        try:
            result = json.loads(lines[0])
        except json.JSONDecodeError as error:
            parse_error = str(error)
    stderr_clean = not stderr_text.strip()
    accepted = (
        not timed_out and process.returncode == 0 and stderr_clean and isinstance(result, dict)
        and result.get("ok") is True and result.get("finished") is True
        and result.get("observed_step_valid") is True and result.get("winner") in (0, 1)
        and result.get("checks", 0) >= 22 and result.get("failures") == []
        and (bool(args.project) or result.get("source_editor_feature") is False)
        and "SCRIPT ERROR:" not in stdout_text and "ERROR:" not in stdout_text
    )
    report = {"ok": accepted, "command": command, "child_pid": process.pid,
              "child_exited": process.poll() is not None, "process_exit_code": process.returncode,
              "wall_seconds": round(time.monotonic() - started, 3), "timeout": timed_out,
              "stderr_clean": stderr_clean, "result_count": len(lines), "parse_error": parse_error,
              "packaged_validation": not bool(args.project), "result": result,
              "stdout_log": str(stdout_path), "stderr_log": str(stderr_path)}
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"ok": accepted, "pid": process.pid, "exit_code": process.returncode,
                      "stderr_clean": stderr_clean, "report": str(report_path)}, ensure_ascii=False))
    return 0 if accepted else 1


if __name__ == "__main__":
    sys.exit(main())
