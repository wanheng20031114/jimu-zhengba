"""Version the authored rules and maps exchanged by the encrypted room handshake."""
import hashlib
import json
import re
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
protocol_source = (ROOT / 'scripts/network/network_protocol.gd').read_text(encoding='utf-8')
build = re.search(r'^const BUILD_ID: String = "([^"]+)"$', protocol_source, re.MULTILINE).group(1)
protocol = int(re.search(r'^const VERSION: int = (\d+)$', protocol_source, re.MULTILINE).group(1))
manifest = {'build': build, 'protocol': protocol, 'files': files}
target = ROOT / 'data/content_manifest.json'
target.write_bytes((json.dumps(manifest, ensure_ascii=False, indent=2) + '\n').encode('utf-8'))
print(f'Content manifest: {len(files)} authored resources, SHA256 {hashlib.sha256(target.read_bytes()).hexdigest()}')
