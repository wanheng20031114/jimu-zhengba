"""Release fingerprints must follow saved rules/maps, not stale export metadata."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('content_manifest', Path(__file__).resolve().parents[1] / 'tools/build_content_manifest.py')
MANIFEST = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MANIFEST)


class ContentManifestTest(unittest.TestCase):
    def test_saved_content_changes_require_a_new_fingerprint(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for directory in ('data/units', 'scenes/maps', 'scripts/network'):
                (root / directory).mkdir(parents=True)
            (root / 'scripts/network/network_protocol.gd').write_text('const BUILD_ID: String = "0.11.0"\nconst VERSION: int = 10\n', encoding='utf-8')
            unit = root / 'data/units/swordsman.tres'
            unit.write_bytes(b'hp = 110\n')
            layout = root / 'scenes/maps/duel_layout.json'
            layout.write_bytes(b'{"width": 100}\n')
            original = MANIFEST.manifest_bytes(root)
            layout.write_bytes(b'{"width": 100}\r\n')
            self.assertEqual(original, MANIFEST.manifest_bytes(root), 'Windows line endings alone must not fork compatibility')
            layout.write_bytes(b'{"width": 120}\n')
            changed_map = MANIFEST.manifest_bytes(root)
            self.assertNotEqual(original, changed_map, 'A real map edit must invalidate the old package')
            unit.write_bytes(b'hp = 145\n')
            self.assertNotEqual(changed_map, MANIFEST.manifest_bytes(root), 'A rule edit must invalidate the old package')
            added = root / 'data/units/shield_guard.tres'
            added.write_bytes(b'hp = 145\n')
            expanded = json.loads(MANIFEST.manifest_bytes(root))
            self.assertIn('data/units/shield_guard.tres', expanded['files'])
            added.unlink()
            self.assertNotIn('data/units/shield_guard.tres', json.loads(MANIFEST.manifest_bytes(root))['files'])


if __name__ == '__main__':
    unittest.main()
