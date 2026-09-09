"""Version the authored rules and maps exchanged by the encrypted room handshake."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
paths = sorted([*ROOT.glob('data/**/*.tres'), *ROOT.glob('scenes/maps/*')])


def canonical_bytes(path: Path) -> bytes:
    content = path.read_bytes()
    if path.suffix in {'.tres', '.tscn', '.json'}:
        content = content.replace(b'\r\n', b'\n')
    return content


files = {path.relative_to(ROOT).as_posix(): hashlib.sha256(canonical_bytes(path)).hexdigest()
         for path in paths if path.is_file()}
manifest = {'build': '0.6.0', 'protocol': 2, 'files': files}
target = ROOT / 'data/content_manifest.json'
target.write_bytes((json.dumps(manifest, ensure_ascii=False, indent=2) + '\n').encode('utf-8'))
print(f'Content manifest: {len(files)} authored resources, SHA256 {hashlib.sha256(target.read_bytes()).hexdigest()}')
