"""Verify the actual Windows package through its explicit network-smoke entry."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    parser.add_argument("--source", action="store_true", help="Run the same Session entry in an editor engine before exporting")
    args = parser.parse_args()
    executable = args.executable.resolve(strict=True)
    directory = ROOT / ".local/network" / ("release-" + uuid.uuid4().hex[:8])
    directory.mkdir(parents=True)
    command = [str(executable), "--headless"]
    if args.source:
        command.extend(("--path", str(ROOT)))
    command.extend(("--", "--network-smoke"))
    with (directory / "stdout.log").open("wb") as out, (directory / "stderr.log").open("wb") as err:
        process = subprocess.Popen(command, cwd=executable.parent, stdout=out, stderr=err, creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            code = process.wait(timeout=90)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=8)
    summary = None
    for line in (directory / "stdout.log").read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("NETWORK_RELEASE_PROBE "):
            summary = json.loads(line.removeprefix("NETWORK_RELEASE_PROBE "))
    stderr = (directory / "stderr.log").read_text(encoding="utf-8", errors="replace")
    success = code == 0 and summary is not None and not summary["failures"] and not stderr.strip()
    value_audit_present = summary is not None and summary.get("resource_value_checks") == 44 and summary.get("checks", 0) >= 101
    if summary is not None:
        success = success and summary["exported_template"] != args.source and value_audit_present
    report = {"passed": success, "summary": summary, "resource_value_audit_present": value_audit_present, "stderr_empty": not stderr.strip(), "log_directory": directory.name}
    (directory / "summary.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print("NETWORK_RELEASE_RESULTS " + json.dumps(report, ensure_ascii=False))
    return 0 if success else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        # Exception strings and native diagnostics may contain endpoint details.
        print("NETWORK_RELEASE_FAILED type=" + type(error).__name__, file=sys.stderr)
        raise SystemExit(1)
