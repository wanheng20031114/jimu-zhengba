"""Build disposable diagnostics from an existing frozen battle-600 source.

Only the copied source is instrumented. Ablations deliberately remove behavior
and must never be mistaken for shipping optimizations or playability results.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

from build_battle_600_benchmark import digest

ENTRIES = {
    "scripts/battle_unit.gd": ["_physics_process", "_apply_velocity", "_refresh_target",
                               "_chase_velocity", "_path_velocity", "_face_direction",
                               "_on_attack_windup_timeout", "_diagnostic_sweep", "_diagnostic_query"],
    "scripts/path_budget.gd": ["_physics_process", "next_position", "try_direct_pursuit"],
    "scripts/construction_navigation.gd": ["has_clear_corridor"],
    "scripts/unit_render_batches.gd": ["_process"],
    "scripts/unit_visual.gd": ["prepare_attack_release"],
    "scripts/game.gd": ["_physics_process", "_process"],
    "scripts/fog_of_war.gd": ["tick", "apply_visibility"],
    "scripts/projectile_pool.gd": ["_physics_process"],
    "scripts/projectile_flight.gd": ["advance", "impact"],
}

COUNTERS = '''class_name Battle600Counters
extends RefCounted
## Inclusive wall time on the main thread; nested entries are not additive.
static var enabled := false
static var instrumented := PROFILED
static var experiment := "baseline"
static var names := PackedStringArray(NAMES)
static var totals := PackedInt64Array()
static var counts := PackedInt64Array()
static var maxima := PackedInt64Array()

static func begin() -> void:
\ttotals.resize(names.size())
\tcounts.resize(names.size())
\tmaxima.resize(names.size())
\ttotals.fill(0)
\tcounts.fill(0)
\tmaxima.fill(0)
\tenabled = instrumented

static func record(index: int, started: int) -> void:
\tvar elapsed := Time.get_ticks_usec() - started
\ttotals[index] += elapsed
\tcounts[index] += 1
\tmaxima[index] = maxi(maxima[index], elapsed)

static func finish(ticks: int, frames: int) -> Dictionary:
\tenabled = false
\tvar result := {}
\tif not instrumented: return result
\tfor index: int in names.size():
\t\tresult[names[index]] = {"calls": counts[index], "total_ms": totals[index] / 1000.0,
\t\t\t"mean_ms_per_tick": totals[index] / (1000.0 * maxi(1, ticks)),
\t\t\t"mean_ms_per_frame": totals[index] / (1000.0 * maxi(1, frames)),
\t\t\t"max_call_ms": maxima[index] / 1000.0}
\treturn result
'''


def replace_once(source: str, old: str, new: str) -> str:
    if source.count(old) != 1:
        raise ValueError(f"Frozen source does not match expected site: {old!r}")
    return source.replace(old, new, 1)


def wrap(source: str, name: str, index: int) -> str:
    pattern = rf"^func {re.escape(name)}\((.*)\) -> ([^:]+):$"
    matches = list(re.finditer(pattern, source, re.MULTILINE))
    if len(matches) != 1:
        raise ValueError(f"Expected one typed method {name}")
    match = matches[0]
    arguments, returns = match.groups()
    passed = ", ".join(part.split(":")[0].strip() for part in arguments.split(",") if part.strip())
    call = f"_diagnostic_original{name}({passed})"
    if returns == "void":
        invoke, finish = f"\t{call}\n", ""
    else:
        invoke, finish = f"\tvar result: {returns} = {call}\n", "\treturn result\n"
    wrapper = (match[0] + "\n\tvar started := Time.get_ticks_usec() if Battle600Counters.enabled else 0\n"
               + invoke + f"\tif started > 0: Battle600Counters.record({index}, started)\n" + finish + "\n"
               + match[0].replace(f"func {name}", f"func _diagnostic_original{name}"))
    return source[:match.start()] + wrapper + source[match.end():]


def prepare(project: Path, profiled: bool) -> dict:
    changed = {}

    def edit(relative: str, transform) -> None:
        file = project / relative
        file.write_text(transform(file.read_text(encoding="utf-8-sig")), encoding="utf-8")
        changed[relative] = digest(file)

    def unit(source: str) -> str:
        source = replace_once(source, "\t\tmove_and_slide()", "\t\t_diagnostic_sweep(proposed)")
        source = replace_once(source, "_space_state.intersect_shape(_target_query, 64)", "_diagnostic_query()")
        return source + '''
func _diagnostic_sweep(proposed: Vector3) -> void:
\tif Battle600Counters.experiment == "no-body-sweep":
\t\tglobal_position = proposed
\telse:
\t\tmove_and_slide()

func _diagnostic_query() -> Array[Dictionary]:
\treturn _space_state.intersect_shape(_target_query, 64)
'''

    edit("scripts/battle_unit.gd", unit)

    def visual(source: str) -> str:
        return replace_once(source, "func _refresh_animation_visibility() -> void:\n",
                            '''func _refresh_animation_visibility() -> void:
\tif Battle600Counters.experiment == "frozen-animation" and is_node_ready():
\t\tlocomotion.active = false
\t\tattack.active = false
\t\treturn
''')

    edit("scripts/unit_visual.gd", visual)
    names = [f"{Path(path).stem}.{name}" for path, methods in ENTRIES.items() for name in methods]
    (project / "tests/battle_600_counters.gd").write_text(
        COUNTERS.replace("PROFILED", str(profiled).lower()).replace("NAMES", json.dumps(names)), encoding="utf-8")
    changed["tests/battle_600_counters.gd"] = digest(project / "tests/battle_600_counters.gd")
    if profiled:
        index = 0
        for relative, methods in ENTRIES.items():
            for name in methods:
                edit(relative, lambda source, name=name, index=index: wrap(source, name, index))
                index += 1

    def harness(source: str) -> str:
        source = replace_once(source, "\tseed(1309600)", '''\tfor argument: String in OS.get_cmdline_user_args():
\t\tif argument.begins_with("--experiment="):
\t\t\tBattle600Counters.experiment = argument.trim_prefix("--experiment=")
\t_check(Battle600Counters.experiment in ["baseline", "no-body-sweep", "no-avoidance", "static-motion",
\t\t"frozen-animation", "no-unit-draw", "frozen-batches", "stationary-pruning"], "known diagnostic experiment")
\tseed(1309600)''')
        source = replace_once(source, '\tawait _populate("cavalry" if cavalry_only else "mixed")', '''\tif Battle600Counters.experiment == "static-motion":
\t\tgame.get_node("StaticMotionGrid").fast_path_enabled = true
\t\tgame.get_node("StaticMotionGrid").configure(game.map_instance, game.get_node("Buildings"), Rect2(-game.map_size * 0.5, game.map_size))
\t\tquality.static_motion = true
\tquality.avoidance_threads = ProjectSettings.get_setting("navigation/avoidance/thread_model/avoidance_use_multiple_threads")
\tawait _populate("cavalry" if cavalry_only else "mixed")
\tfor unit: BattleUnit in get_nodes_in_group("units"):
\t\tif Battle600Counters.experiment == "no-avoidance": unit.navigation_agent.avoidance_enabled = false
\t\tif Battle600Counters.experiment == "stationary-pruning":
\t\t\tunit.prune_stationary_avoidance = true
\t\t\tif not unit._avoidance_moving: unit.navigation_agent.max_neighbors = 0
\tif Battle600Counters.experiment == "no-unit-draw": game.get_node("UnitRenderBatches").visible = false''')
        source = replace_once(source, "\t_command_armies()", '''\tif Battle600Counters.experiment == "frozen-batches": game.get_node("UnitRenderBatches").set_process(false)
\t_command_armies()''')
        source = replace_once(source, "\tprobe.begin_sample()", "\tprobe.begin_sample()\n\tBattle600Counters.begin()")
        source = replace_once(source, "\tvar logic: Array[float] = probe.end_sample()", "\tvar logic: Array[float] = probe.end_sample()\n\tvar entries := Battle600Counters.finish(game.simulation_tick - start_tick, frame_ms.size())")
        source = replace_once(source, "\tphases.append(phase)", '''\tphase.entry_timings = entries
\tphase.motion_fast_steps = game.get_node("StaticMotionGrid").fast_steps
\tphase.motion_native_steps = game.get_node("StaticMotionGrid").native_steps
\tphase.submitted_parts = game.get_node("UnitRenderBatches").submitted_parts
\tphases.append(phase)''')
        source = replace_once(source, '"schema": 1, "run_id": run_id,', '''"schema": 1, "run_id": run_id,
\t\t"diagnostic_experiment": Battle600Counters.experiment, "instrumented": Battle600Counters.instrumented,
\t\t"diagnostic_warning": "Ablations remove behavior and are cost attribution only. Inclusive entry timers overlap and add overhead. They are not accepted optimizations.",''')
        return source

    edit("tests/battle_600_performance.gd", harness)
    return changed


def build(base: Path, output: Path, editor: Path, profiled: bool) -> None:
    base, output = base.resolve(), output.resolve()
    if output.exists():
        raise ValueError("Choose a fresh diagnostics output; preserve earlier evidence")
    receipt = json.loads((base / "receipt.json").read_text(encoding="utf-8"))
    if digest(base / "bin/battle-600.pck") != receipt["pck_sha256"]:
        raise ValueError("Base PCK differs from its frozen receipt")
    for relative, expected in receipt["source_sha256"].items():
        if relative == "project.godot":
            expected = receipt["benchmark_project_sha256"]
        if digest(base / "source" / relative) != expected:
            raise ValueError(f"Base source changed after freezing: {relative}")
    project = output / "source"
    shutil.copytree(base / "source", project)
    changed = prepare(project, profiled)
    bundle = output / "bin"
    bundle.mkdir()
    steps = []
    for name, arguments in (
        ("import", ["--editor", "--import", "--quit"]),
        ("export", ["--export-pack", "Battle 600", str(bundle / "battle-600.pck")]),
    ):
        with (output / f"{name}.stdout.log").open("wb") as stdout, (output / f"{name}.stderr.log").open("wb") as stderr:
            process = subprocess.Popen([str(editor), "--headless", "--path", str(project), *arguments],
                                       stdout=stdout, stderr=stderr,
                                       creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
            print(f"{name}: PID {process.pid}", flush=True)
            try:
                code = process.wait(timeout=180)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=10)
            steps.append({"step": name, "pid": process.pid, "exit_code": code})
        errors = (output / f"{name}.stderr.log").read_text(encoding="utf-8", errors="replace")
        if code or "SCRIPT ERROR" in errors or "ERROR:" in errors:
            raise RuntimeError(f"{name} failed: inspect native logs")
    shutil.copy2(base / "bin/battle-600.exe", bundle / "battle-600.exe")
    evidence = {"base_pck_sha256": receipt["pck_sha256"], "base_head": receipt["head"],
                "base_source_sha256": receipt["source_sha256"], "instrumented": profiled,
                "diagnostic_source_sha256": changed, "pck_sha256": digest(bundle / "battle-600.pck"),
                "editor_sha256": digest(editor), "release_template_sha256": digest(bundle / "battle-600.exe"),
                "build_steps": steps}
    (output / "receipt.json").write_text(json.dumps(evidence, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"Disposable diagnostic executable: {bundle / 'battle-600.exe'}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--editor", type=Path, default=Path("C:/Program Files/Godot/Godot.exe"))
    parser.add_argument("--profile", action="store_true")
    args = parser.parse_args()
    build(args.base, args.output, args.editor, args.profile)
