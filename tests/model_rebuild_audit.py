"""Regenerate unit sources only in an owned temp directory; compare saved assets.

No project import, bake or asset overwrite. Godot verifies existing native mesh
arrays and compares saved animation keys with freshly authored source poses.
"""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("unit_builder", ROOT / "tools/build_units.py")
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)
SOURCE = BUILDER.OUT


def run():
    with tempfile.TemporaryDirectory(prefix="medieval-unit-rebuild-") as temporary:
        output = Path(temporary).resolve()
        assert output.is_relative_to(Path(tempfile.gettempdir()).resolve())
        BUILDER.OUT = output
        models = [BUILDER.infantry("swordsman"), BUILDER.infantry("archer", True),
                  BUILDER.horse_knight(), BUILDER.catapult(), BUILDER.cannon()]
        matches = []
        for model in models:
            model.save()
            for relative in [Path(model.name) / "parts.json"] + [
                    Path(model.name) / (part + ".glb") for part in model.parts]:
                rebuilt = (output / relative).read_bytes()
                saved = (SOURCE / relative).read_bytes()
                assert hashlib.sha256(rebuilt).digest() == hashlib.sha256(saved).digest(), relative
                matches.append(str(relative).replace("\\", "/"))
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = subprocess.SW_HIDE
        godot = Path(os.environ.get("GODOT_EXE", r"C:\Program Files\Godot\Godot.exe"))
        result = subprocess.run([
            str(godot), "--headless", "--path", str(ROOT), "--script",
            "res://tests/model_rebuild_audit.gd", "--", str(output)
        ], cwd=ROOT, timeout=30, capture_output=True, text=True, encoding="utf-8",
            startupinfo=startup, creationflags=subprocess.CREATE_NO_WINDOW)
        (ROOT / "tests/model_rebuild_audit.log").write_text(result.stdout, encoding="utf-8")
        (ROOT / "tests/model_rebuild_audit-errors.log").write_text(result.stderr, encoding="utf-8")
        print(result.stdout)
        if result.stderr:
            print(result.stderr)
        result.check_returncode()
        report_path = ROOT / "tests/model_rebuild_audit.json"
        report = json.loads(report_path.read_text(encoding="utf-8"))
        report["source_files_byte_identical"] = matches
        report["source_file_count"] = len(matches)
        report["project_assets_overwritten"] = False
        report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"BYTE_IDENTICAL {len(matches)} source files; native scene audit complete")


if __name__ == "__main__":
    run()
