"""Build the isolated native relay PCK with verified Godot 4.7.2 release templates.

The build never contacts a game server or copies its private configuration.
An official editor performs the export; the resulting service runs only the
unchanged release template next to its identically named PCK.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RUNTIME_VERSION = "4.7.2-stable"
TEMPLATE_ARCHIVE_SHA256 = "f298490b8d44d934be425a5a65a51bf15f422428b229a06a6e11d9ffea248011"
EDITOR_WINDOWS_SHA256 = "ab1824f85bfd8e0e4128182c000c4003a3e042245b2967848d089b2a04b22424"
TEMPLATE_SHA256 = {
    "linux_release.x86_64": "d9f79ab89b5ae369aeed11c6052d402e8218cd503bf85b4a235f9c30c46a7c63",
    "windows_release_x86_64.exe": "d34d36f3be1a6c49c56525ae86469b92e4f417ddf0b43cf00dd80c385c4b0562",
}
SOURCE_FILES = (
    "server/relay_project.godot",
    "server/relay_main.gd",
    "server/relay_bootstrap.gd",
    "server/relay_bootstrap.tscn",
    "server/relay.tscn",
    "server/relay_server.gd",
    "scripts/network/network_protocol.gd",
    "data/content_manifest.json",
)


def digest(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def fetch_templates(folder: Path) -> None:
    """Verify the full official archive before extracting the two required files."""
    folder.mkdir(parents=True, exist_ok=True)
    archive = folder / "Godot_v4.7.2-stable_export_templates.tpz"
    url = "https://github.com/godotengine/godot-builds/releases/download/4.7.2-stable/" + archive.name
    if not archive.exists():
        partial = archive.with_suffix(".download")
        with urllib.request.urlopen(url, timeout=45) as response, partial.open("wb") as target:
            if response.status != 200:
                raise RuntimeError("The official template archive must be a complete response")
            while chunk := response.read(4 * 1024 * 1024):
                target.write(chunk)
        if digest(partial) != TEMPLATE_ARCHIVE_SHA256:
            raise RuntimeError("Downloaded official template archive checksum mismatch")
        partial.replace(archive)
    if digest(archive) != TEMPLATE_ARCHIVE_SHA256:
        raise RuntimeError("Official template archive checksum mismatch")
    files = {}
    with zipfile.ZipFile(archive) as package:
        for name in ("linux_release.x86_64", "windows_release_x86_64.exe"):
            data = package.read("templates/" + name)
            (folder / name).write_bytes(data)
            files[name] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
    receipt = {"version": RUNTIME_VERSION, "source_url": url,
               "archive_sha256": TEMPLATE_ARCHIVE_SHA256, "archive_bytes": archive.stat().st_size, "files": files}
    (folder / "receipt.json").write_text(json.dumps(receipt, indent=2), encoding="utf-8")


def checked_templates(folder: Path) -> dict[str, Path]:
    receipt = json.loads((folder / "receipt.json").read_text(encoding="utf-8"))
    if receipt.get("version") != RUNTIME_VERSION or receipt.get("archive_sha256") != TEMPLATE_ARCHIVE_SHA256:
        raise RuntimeError("A verified official 4.7.2 template archive receipt is required")
    result = {}
    for name in ("linux_release.x86_64", "windows_release_x86_64.exe"):
        path = folder / name
        if digest(path) != TEMPLATE_SHA256[name] or receipt["files"][name]["sha256"] != TEMPLATE_SHA256[name] or path.stat().st_size != receipt["files"][name]["bytes"]:
            raise RuntimeError("Cached release template checksum mismatch")
        result[name] = path
    return result


def run_native(editor: Path, project: Path, arguments: list[str], log: Path) -> dict:
    flags = subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS if os.name == "nt" else 0
    with log.with_suffix(".stdout.log").open("wb") as stdout, log.with_suffix(".stderr.log").open("wb") as stderr:
        process = subprocess.Popen([str(editor), "--headless", "--path", str(project), "--log-file", str(log.with_suffix(".engine.log")), *arguments], stdout=stdout, stderr=stderr, creationflags=flags)
        try:
            result = process.wait(timeout=90)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
    text = log.with_suffix(".stderr.log").read_text(encoding="utf-8", errors="replace")
    if result != 0 or "SCRIPT ERROR" in text or "ERROR:" in text:
        raise RuntimeError("Native relay export failed; inspect the bounded build logs")
    return {"pid": process.pid, "exit_code": result, "helper_exited": process.poll() is not None, "stderr_bytes": log.with_suffix(".stderr.log").stat().st_size}


def build(editor: Path, templates: Path, output: Path) -> dict:
    editor = editor.resolve()
    output = output.resolve()
    if digest(editor) != EDITOR_WINDOWS_SHA256:
        raise RuntimeError("Use the pinned official Windows Godot 4.7.2 editor to export this relay")
    native_templates = checked_templates(templates.resolve())
    project = output / "project"
    project.mkdir(parents=True, exist_ok=True)
    source_hashes = {}
    for relative in SOURCE_FILES:
        original = ROOT / relative
        destination = project / ("project.godot" if relative == "server/relay_project.godot" else relative)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(original, destination)
        source_hashes[relative] = digest(original)
    presets = []
    targets = [("Linux", "Relay Linux", "linux_release.x86_64", "linux", "jimu-relay"),
               ("Windows Desktop", "Relay Windows", "windows_release_x86_64.exe", "windows", "jimu-relay.exe")]
    for index, (platform, name, template_name, _, _) in enumerate(targets):
        presets.append(f'''[preset.{index}]
name={json.dumps(name)}
platform={json.dumps(platform)}
runnable=true
dedicated_server=true
custom_features="dedicated_server"
export_filter="all_resources"
include_filter="data/*.json"
exclude_filter=""
encrypt_pck=false
encrypt_directory=false
script_export_mode=2

[preset.{index}.options]
custom_template/release={json.dumps(native_templates[template_name].as_posix())}
binary_format/architecture="x86_64"
binary_format/embed_pck=false
application/modify_resources=false
''')
    (project / "export_presets.cfg").write_text("\n".join(presets), encoding="utf-8")
    build_steps = {"import": run_native(editor, project, ["--editor", "--import", "--quit"], output / "import")}
    receipts = {}
    for platform, name, template_name, directory, executable_name in targets:
        bundle = output / directory
        bundle.mkdir(exist_ok=True)
        pck = bundle / "jimu-relay.pck"
        build_steps[directory] = run_native(editor, project, ["--export-pack", name, str(pck)], output / (directory + "-export"))
        executable = bundle / executable_name
        shutil.copy2(native_templates[template_name], executable)
        receipt = {"schema_version": 1, "runtime_version": RUNTIME_VERSION, "platform": platform,
                   "built_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
                   "template_archive_sha256": TEMPLATE_ARCHIVE_SHA256,
                   "template_sha256": digest(executable), "editor_sha256": digest(editor),
                   "files": {p.name: {"sha256": digest(p), "bytes": p.stat().st_size} for p in [executable, pck]},
                   "source_sha256": source_hashes,
                   "bootstrap": "res://server/relay_bootstrap.tscn",
                   "expected_features": {"editor": False, "debug": False, "dedicated_server": True}}
        (bundle / "build-receipt.json").write_text(json.dumps(receipt, indent=2), encoding="utf-8")
        receipts[directory] = receipt
    result = {"build_steps": build_steps, "packages": receipts}
    (output / "build-summary.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, required=True)
    parser.add_argument("--templates", type=Path, required=True, help="Verified templates and official archive receipt")
    parser.add_argument("--output", type=Path, required=True, help="Dedicated build directory; no game assets or credentials copied")
    parser.add_argument("--fetch-templates", action="store_true", help="Download and verify the official archive before building")
    arguments = parser.parse_args()
    try:
        if arguments.fetch_templates:
            fetch_templates(arguments.templates.resolve())
        result = build(arguments.editor, arguments.templates, arguments.output)
        print(json.dumps({"state": "built", "packages": {k: v["files"] for k, v in result["packages"].items()}, "build_steps": result["build_steps"]}))
        return 0
    except Exception as error:
        print("RELAY_BUILD_FAILED type=" + type(error).__name__)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
