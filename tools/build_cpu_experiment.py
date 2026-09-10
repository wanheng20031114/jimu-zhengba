"""Export the separate CPU experiment without touching stable builds or Relay."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', type=Path, default=Path('C:/Program Files/Godot/Godot.exe'))
    parser.add_argument('--output', type=Path, default=ROOT / 'builds/windows-cpu-experiment-0.11.1')
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.name.startswith('windows-cpu-experiment-'):
        raise SystemExit('Output must be a separate windows-cpu-experiment-* directory.')
    protocol = (ROOT / 'scripts/network/network_protocol.gd').read_text(encoding='utf-8')
    release = re.search(r'^const RELEASE_ID: String = "([^"]+)"$', protocol, re.M).group(1)
    if '-cpu-exp.' not in release:
        raise SystemExit('This exporter requires an explicitly labeled CPU experiment.')
    output.mkdir(parents=True, exist_ok=True)
    logs = ROOT / '.local/cpu-experiment-export'
    logs.mkdir(parents=True, exist_ok=True)
    executable = output / '积木争霸.exe'
    pack = output / '积木争霸.pck'
    command = [str(args.godot.resolve()), '--headless', '--path', str(ROOT),
               '--log-file', str(logs / 'engine.log'), '--export-release', 'Windows Desktop', str(executable)]
    with (logs / 'stdout.log').open('wb') as stdout, (logs / 'stderr.log').open('wb') as stderr:
        process = subprocess.Popen(command, stdout=stdout, stderr=stderr, creationflags=subprocess.CREATE_NO_WINDOW)
        print(json.dumps({'export_pid': process.pid, 'output': str(output)}, ensure_ascii=False), flush=True)
        try:
            code = process.wait(timeout=600)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=15)
            raise RuntimeError('Experimental export timed out; its Godot process was stopped.')
    if code != 0 or not executable.is_file() or not pack.is_file():
        raise RuntimeError('Experimental export failed; inspect the isolated export logs.')
    readme = output / 'START_HERE.txt'
    readme.write_text((ROOT / 'docs/cpu-experiment.md').read_text(encoding='utf-8'), encoding='utf-8')
    archive = output.parent / ('积木争霸-' + release + '-Windows-x64.zip')
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as package:
        for path in (executable, pack, readme):
            package.write(path, '积木争霸-CPU实验版/' + path.name)
    receipt = {
        'release': release,
        'source_commit': subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip(),
        'export_pid': process.pid, 'export_exit_code': code, 'export_process_exited': process.poll() is not None,
        'files': {str(path): {'bytes': path.stat().st_size, 'sha256': sha256(path)}
                  for path in (executable, pack, archive)},
        'relay_updated': False, 'stable_output_replaced': False,
    }
    (logs / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(receipt, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
