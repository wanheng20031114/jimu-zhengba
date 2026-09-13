"""Freeze the current workspace into a separate 600-unit Windows release benchmark.

The normal project, export presets and published game are never rewritten.
Run the resulting battle-600.exe with -- --run-id=... --output=<absolute directory>.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
HARNESS = (
    "tests/battle_600_performance.gd",
    "tests/skirmish_stress_test.gd",
    "tests/skirmish_profile_probe.gd",
    "tests/skirmish_profile_probe.tscn",
)


def digest(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def build(output: Path, editor: Path, template: Path, base: Path | None = None, overrides: list[str] | None = None) -> None:
    output = output.resolve()
    if output.exists():
        raise ValueError("Choose a new output directory to preserve earlier benchmark evidence")
    output.mkdir(parents=True)
    project = output / "source"
    project.mkdir()
    overrides = overrides or []
    base_receipt = None
    if base is not None:
        base = base.resolve()
        base_receipt = json.loads((base / "receipt.json").read_text(encoding="utf-8"))
        if digest(base / "bin/battle-600.pck") != base_receipt["pck_sha256"]:
            raise ValueError("Base PCK no longer matches its receipt")
        for relative, expected in base_receipt["source_sha256"].items():
            if relative == "project.godot":
                expected = base_receipt["benchmark_project_sha256"]
            if digest(base / "source" / relative) != expected:
                raise ValueError(f"Frozen base source changed: {relative}")
        paths = list(base_receipt["source_sha256"]) + overrides
    else:
        if overrides:
            raise ValueError("--override requires --base")
        paths = subprocess.check_output(
            ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT
        ).decode("utf-8").split("\0")
    selected = sorted(set(HARNESS) | set(overrides) | {
        path for path in paths
        if path.startswith(("assets/", "scripts/", "scenes/", "data/", "shaders/", "resources/"))
        or path in ("project.godot", "default_bus_layout.tres")
    })
    hashes = {}
    for relative in selected:
        if Path(relative).is_absolute() or ".." in Path(relative).parts:
            raise ValueError("Overrides must be repository-relative paths")
        original = ROOT / relative if base is None or relative in overrides else base / "source" / relative
        if not original.is_file():
            if relative in overrides:
                raise ValueError(f"Missing explicit override: {relative}")
            continue
        target = project / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(original, target)
        hashes[relative] = digest(target)
    # Imported resources are copied, never hard-linked to editor-owned caches.
    import_source = ROOT if base is None else base / "source"
    shutil.copytree(import_source / ".godot/imported", project / ".godot/imported")
    config = (project / "project.godot").read_text(encoding="utf-8-sig")
    # Official release templates still require a main scene during startup.
    # The custom SceneTree replaces that scene before benchmark preparation.
    if 'run/main_loop_type="Battle600Performance"' not in config:
        config = config.replace("[application]", '[application]\nrun/main_loop_type="Battle600Performance"', 1)
    (project / "project.godot").write_text(config, encoding="utf-8")
    presets = f'''[preset.0]
name="Battle 600"
platform="Windows Desktop"
runnable=true
export_filter="all_resources"
include_filter="data/*.json,scenes/maps/*_layout.json,scripts/network/*.crt"
exclude_filter="assets/audio/sources/*"
script_export_mode=2

[preset.0.options]
custom_template/release="{template.resolve().as_posix()}"
binary_format/architecture="x86_64"
binary_format/embed_pck=false
application/modify_resources=false
texture_format/s3tc_bptc=true
'''
    (project / "export_presets.cfg").write_text(presets, encoding="utf-8")
    bundle = output / "bin"
    bundle.mkdir()
    steps = []
    for name, arguments in (
        ("import", ["--editor", "--import", "--quit"]),
        ("export", ["--export-pack", "Battle 600", str(bundle / "battle-600.pck")]),
    ):
        with (output / f"{name}.stdout.log").open("wb") as stdout, (output / f"{name}.stderr.log").open("wb") as stderr:
            process = subprocess.Popen(
                [str(editor), "--headless", "--path", str(project), *arguments],
                stdout=stdout, stderr=stderr,
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
            )
            print(f"{name}: PID {process.pid}", flush=True)
            try:
                code = process.wait(timeout=180)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=10)
            steps.append({"step": name, "pid": process.pid, "exit_code": code})
        errors = (output / f"{name}.stderr.log").read_text(encoding="utf-8", errors="replace")
        if code != 0 or "SCRIPT ERROR" in errors or "ERROR:" in errors:
            raise RuntimeError(f"{name} failed; inspect {output / (name + '.stderr.log')}")
    shutil.copy2(template, bundle / "battle-600.exe")
    receipt = {
        "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "workspace_status": subprocess.check_output(["git", "status", "--short"], cwd=ROOT, text=True),
        "source_sha256": hashes,
        "editor_sha256": digest(editor),
        "release_template_sha256": digest(template),
        "pck_sha256": digest(bundle / "battle-600.pck"),
        "benchmark_project_sha256": digest(project / "project.godot"),
        "build_steps": steps,
    }
    if base_receipt is not None:
        receipt["base_pck_sha256"] = base_receipt["pck_sha256"]
        receipt["overrides"] = overrides
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"Frozen release benchmark: {bundle / 'battle-600.exe'}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--base", type=Path, help="Preserve all content from a frozen build except explicit overrides")
    parser.add_argument("--override", action="append", default=[], help="Repository-relative source to replace in --base (repeatable)")
    parser.add_argument("--editor", type=Path, default=Path("C:/Program Files/Godot/Godot.exe"))
    parser.add_argument("--template", type=Path, default=Path(os.environ["APPDATA"]) / "Godot/export_templates/4.6.3.stable/windows_release_x86_64.exe")
    args = parser.parse_args()
    build(args.output, args.editor, args.template, args.base, args.override)
