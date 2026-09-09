"""Check release logs are on disk before an abnormal process exit, without causing a crash."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def records(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(line.removeprefix("ASHEN_DIAGNOSTIC "))
            for line in path.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
            if line.startswith("ASHEN_DIAGNOSTIC ") and line.endswith("\n")]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    args = parser.parse_args()
    executable = args.executable.resolve(strict=True)
    directory = ROOT / ".local/crash-2026-09-10" / ("logging-" + uuid.uuid4().hex[:8])
    directory.mkdir(parents=True)
    checks = []
    children = []
    for normal in (False, True):
        name = "normal" if normal else "interrupted"
        engine_log = directory / (name + ".engine.log")
        stderr_log = directory / (name + ".stderr.log")
        command = [str(executable), "--headless", "--audio-driver", "Dummy", "--log-file", str(engine_log)]
        if normal:
            command += ["--quit-after", "3"]
        with (directory / (name + ".stdout.log")).open("wb") as stdout, stderr_log.open("wb") as stderr:
            child = subprocess.Popen(command, cwd=executable.parent, stdout=stdout, stderr=stderr,
                                     creationflags=subprocess.CREATE_NO_WINDOW)
            try:
                if normal:
                    child.wait(timeout=15)
                else:
                    deadline = time.monotonic() + 22
                    while time.monotonic() < deadline and child.poll() is None:
                        if any(row["event"] == "health" for row in records(engine_log)):
                            break
                        time.sleep(0.1)
                    live = records(engine_log)
                    checks.append(("startup_flushed_while_process_alive", child.poll() is None and any(row["event"] == "startup" for row in live)))
                    checks.append(("timer_health_flushed_while_process_alive", child.poll() is None and any(row["event"] == "health" for row in live)))
            finally:
                if child.poll() is None:
                    child.terminate()
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait(timeout=5)
            rows = records(engine_log)
            children.append({"pid": child.pid, "exited": child.poll() is not None, "code": child.returncode})
            checks.append((name + "_stderr_clean", not stderr_log.read_bytes().strip()))
            checks.append((name + "_startup_retained", any(row["event"] == "startup" for row in rows)))
            checks.append((name + "_process_identity", bool(rows) and all(row["pid"] == child.pid for row in rows)))
            has_exit = any(row["event"] == "session_exit" for row in rows)
            checks.append((name + "_normal_exit_marker", has_exit == normal))
            if normal:
                checks.append(("normal_zero_exit_code", child.returncode == 0))
    report = {"checks": len(checks), "failures": [label for label, ok in checks if not ok],
              "children": children, "directory": str(directory)}
    (directory / "result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("DIAGNOSTIC_LOGGING " + json.dumps(report))
    return 0 if not report["failures"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
