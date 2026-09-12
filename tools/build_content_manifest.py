"""Version the authored rules and maps exchanged by the encrypted room handshake."""
import argparse
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def canonical_bytes(path: Path) -> bytes:
    content = path.read_bytes()
    if path.suffix in {'.tres', '.tscn', '.json'}:
        content = content.replace(b'\r\n', b'\n')
    return content


def manifest_bytes(root: Path = ROOT) -> bytes:
    paths = sorted([*root.glob('data/**/*.tres'), *root.glob('scenes/maps/*')])
    files = {path.relative_to(root).as_posix(): hashlib.sha256(canonical_bytes(path)).hexdigest()
             for path in paths if path.is_file()}
    protocol_source = (root / 'scripts/network/network_protocol.gd').read_text(encoding='utf-8')
    build = re.search(r'^const BUILD_ID: String = "([^"]+)"$', protocol_source, re.MULTILINE).group(1)
    protocol = int(re.search(r'^const VERSION: int = (\d+)$', protocol_source, re.MULTILINE).group(1))
    manifest = {'build': build, 'protocol': protocol, 'files': files}
    return (json.dumps(manifest, ensure_ascii=False, indent=2) + '\n').encode('utf-8')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Reject a stale manifest without rewriting it')
    args = parser.parse_args()
    expected = manifest_bytes()
    target = ROOT / 'data/content_manifest.json'
    if args.check:
        if not target.exists() or target.read_bytes() != expected:
            print('CONTENT_MANIFEST_STALE: regenerate before exporting this source snapshot')
            return 1
    else:
        target.write_bytes(expected)
    print(f'Content manifest: {len(json.loads(expected)["files"])} authored resources, SHA256 {hashlib.sha256(expected).hexdigest()}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
