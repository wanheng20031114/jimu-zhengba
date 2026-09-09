"""Bounded six-player native rendering benchmark; preserve all existing user processes."""
from __future__ import annotations
import json
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
BUILD = re.search(r'const BUILD_ID: String = "([0-9]+\.[0-9]+\.[0-9]+)"',
                  (ROOT / "scripts/network/network_protocol.gd").read_text(encoding="utf-8")).group(1)
VERSION_SUFFIX = BUILD.replace(".", "")
REPORT = ROOT / f"artifacts/six-player-performance-{VERSION_SUFFIX}.json"
LOG = ROOT / f".local/six-player-performance-{VERSION_SUFFIX}"


def machine_activity() -> dict:
    # Read only a narrow public inventory, never whole process command lines.
    query = r"""
    $rows = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^(Godot|Godot_console|AshenCrown|python)\.exe$' } | ForEach-Object {
        $role = if ($_.CommandLine -match '--headless|--check-only|--script|network_game_live_runner|run_release_match_smoke') { 'validation_helper' } elseif ($_.CommandLine -match '--editor') { 'user_editor' } elseif ($_.Name -eq 'AshenCrown.exe') { 'user_game' } else { 'background_process' }
        [pscustomobject]@{ pid=$_.ProcessId; name=$_.Name; role=$role }
    })
    [pscustomobject]@{ processes=$rows; cpu=(Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name) } | ConvertTo-Json -Depth 4 -Compress
    """
    result = subprocess.run(["powershell", "-NoProfile", "-Command", query], capture_output=True, text=True, encoding="utf-8", check=True, creationflags=subprocess.CREATE_NO_WINDOW)
    return json.loads(result.stdout)


def main() -> int:
    before = machine_activity()
    helpers = [p for p in before["processes"] if p["role"] == "validation_helper"]
    if helpers:
        print(json.dumps({"started": False, "reason": "Other validation helpers are still active; wait before performance sampling.", "helpers": helpers}))
        return 2
    LOG.parent.mkdir(exist_ok=True)
    executable = Path(r"C:/Program Files/Godot/Godot.exe")
    command = [str(executable), "--path", str(ROOT), "--rendering-method", "forward_plus", "--rendering-driver", "vulkan", "--windowed", "--resolution", "1600x900", "--log-file", str(LOG.with_suffix(".engine.log")), "--script", "res://tests/six_player_performance.gd", "--", "--3v3"]
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = 0
    started = time.monotonic()
    timed_out = False
    with LOG.with_suffix(".stdout.log").open("wb") as stdout, LOG.with_suffix(".stderr.log").open("wb") as stderr:
        process = subprocess.Popen(command, cwd=ROOT, stdout=stdout, stderr=stderr, startupinfo=startup, creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            process.wait(timeout=170)
        except subprocess.TimeoutExpired:
            timed_out = True
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
    output = LOG.with_suffix(".stdout.log").read_text(encoding="utf-8-sig", errors="replace")
    errors = LOG.with_suffix(".stderr.log").read_text(encoding="utf-8-sig", errors="replace")
    after = machine_activity()
    report = json.loads(REPORT.read_text(encoding="utf-8")) if REPORT.exists() else {}
    report["run"] = {"child_pid": process.pid, "elapsed_seconds": round(time.monotonic()-started,3), "exit_code": process.returncode, "timed_out": timed_out, "machine_activity_before": before, "machine_activity_after": after, "shared_workstation": True, "user_processes_preserved": True, "notes": "Started only after all other Godot/ENet validation helpers stopped. Existing user game/editor and unrelated background processes were deliberately left running; GPU/CPU contention can affect these sample values."}
    report["run"]["script_errors"] = "SCRIPT ERROR:" in output or "SCRIPT ERROR:" in errors
    report["run"]["stderr_empty"] = not errors.strip()
    report["run"]["helper_cleanup_verified"] = not any(p["pid"] == process.pid for p in after["processes"])
    report["ok"] = process.returncode == 0 and not timed_out and not errors.strip() and "SCRIPT ERROR:" not in output and report.get("build") == BUILD and [phase["starting_units"] for phase in report.get("phases",[])] == [204, 672] and not report.get("failures",[]) and "SKIRMISH_STRESS_RESULT 3v3" in output
    REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
    print(json.dumps({"ok":report["ok"], "report":str(REPORT), "phases":[{"name":p["name"],"units":p["starting_units"],"ending_units":p["ending_units"],"fps":p["measured_fps"],"tps":p["observed_tps"],"logic_p95_ms":p["physics_logic_ms"]["p95"],"frame_p95_ms":p["frame_ms"]["p95"],"frame_p99_ms":p["frame_ms"]["p99"]} for p in report.get("phases",[])]},ensure_ascii=False))
    return 0 if report["ok"] else 1

if __name__ == "__main__":
    sys.exit(main())
