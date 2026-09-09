"""Bounded 3v3/4v4 rendering benchmark; preserve all existing user processes."""
from __future__ import annotations
import json
import argparse
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
BUILD = re.search(r'const BUILD_ID: String = "([0-9]+\.[0-9]+\.[0-9]+)"',
                  (ROOT / "scripts/network/network_protocol.gd").read_text(encoding="utf-8")).group(1)
VERSION_SUFFIX = BUILD.replace(".", "")


def machine_activity() -> dict:
    # Read only a narrow public inventory, never whole process command lines.
    query = r"""
    $rows = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^(Godot|Godot_console|积木争霸|python)\.exe$' } | ForEach-Object {
        $role = if ($_.CommandLine -match '--headless|--check-only|--script|network_game_live_runner|run_release_match_smoke') { 'validation_helper' } elseif ($_.CommandLine -match '--editor') { 'user_editor' } elseif ($_.Name -eq '积木争霸.exe') { 'user_game' } else { 'background_process' }
        [pscustomobject]@{ pid=$_.ProcessId; name=$_.Name; role=$role }
    })
    [pscustomobject]@{ processes=$rows; cpu=(Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name) } | ConvertTo-Json -Depth 4 -Compress
    """
    result = subprocess.run(["powershell", "-NoProfile", "-Command", query], capture_output=True, text=True, encoding="utf-8", check=True, creationflags=subprocess.CREATE_NO_WINDOW)
    return json.loads(result.stdout)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("3v3", "4v4"), default="3v3")
    args = parser.parse_args()
    player_label = "eight" if args.mode == "4v4" else "six"
    expected_rosters = [272, 896] if args.mode == "4v4" else [204, 672]
    report_path = ROOT / f"artifacts/{player_label}-player-performance-{VERSION_SUFFIX}.json"
    log = ROOT / f".local/{player_label}-player-performance-{VERSION_SUFFIX}"
    before = machine_activity()
    helpers = [p for p in before["processes"] if p["role"] == "validation_helper"]
    if helpers:
        print(json.dumps({"started": False, "reason": "Other validation helpers are still active; wait before performance sampling.", "helpers": helpers}))
        return 2
    log.parent.mkdir(exist_ok=True)
    executable = Path(r"C:/Program Files/Godot/Godot.exe")
    command = [str(executable), "--path", str(ROOT), "--rendering-method", "forward_plus", "--rendering-driver", "vulkan", "--windowed", "--resolution", "1600x900", "--log-file", str(log.with_suffix(".engine.log")), "--script", "res://tests/six_player_performance.gd", "--", f"--mode={args.mode}"]
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = 0
    started = time.monotonic()
    timed_out = False
    with log.with_suffix(".stdout.log").open("wb") as stdout, log.with_suffix(".stderr.log").open("wb") as stderr:
        process = subprocess.Popen(command, cwd=ROOT, stdout=stdout, stderr=stderr, startupinfo=startup, creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            process.wait(timeout=170)
        except subprocess.TimeoutExpired:
            timed_out = True
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
    output = log.with_suffix(".stdout.log").read_text(encoding="utf-8-sig", errors="replace")
    errors = log.with_suffix(".stderr.log").read_text(encoding="utf-8-sig", errors="replace")
    after = machine_activity()
    report = json.loads(report_path.read_text(encoding="utf-8")) if report_path.exists() else {}
    report["run"] = {"child_pid": process.pid, "elapsed_seconds": round(time.monotonic()-started,3), "exit_code": process.returncode, "timed_out": timed_out, "machine_activity_before": before, "machine_activity_after": after, "shared_workstation": True, "user_processes_preserved": True, "notes": "Started only after all other Godot/ENet validation helpers stopped. Existing user game/editor and unrelated background processes were deliberately left running; GPU/CPU contention can affect these sample values."}
    report["run"]["script_errors"] = "SCRIPT ERROR:" in output or "SCRIPT ERROR:" in errors
    report["run"]["stderr_empty"] = not errors.strip()
    report["run"]["helper_cleanup_verified"] = not any(p["pid"] == process.pid for p in after["processes"])
    report["ok"] = process.returncode == 0 and not timed_out and not errors.strip() and "SCRIPT ERROR:" not in output and report.get("build") == BUILD and report.get("mode") == args.mode and [phase["starting_units"] for phase in report.get("phases",[])] == expected_rosters and not report.get("failures",[]) and f"SKIRMISH_STRESS_RESULT {args.mode}" in output
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
    print(json.dumps({"ok":report["ok"], "report":str(report_path), "phases":[{"name":p["name"],"units":p["starting_units"],"ending_units":p["ending_units"],"fps":p["measured_fps"],"tps":p["observed_tps"],"logic_p95_ms":p["physics_logic_ms"]["p95"],"frame_p95_ms":p["frame_ms"]["p95"],"frame_p99_ms":p["frame_ms"]["p99"]} for p in report.get("phases",[])]},ensure_ascii=False))
    return 0 if report["ok"] else 1

if __name__ == "__main__":
    sys.exit(main())
