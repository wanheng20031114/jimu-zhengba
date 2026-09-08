"""Extract the old audio to an isolated project; never touch product files."""
import json
import math
from pathlib import Path
import shutil
import subprocess
import wave
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'artifacts' / 'audibility_baseline'
OUT.mkdir(parents=True, exist_ok=True)
(OUT / 'old_audio').mkdir(exist_ok=True)
(OUT / '.gdignore').write_text('', encoding='utf-8')
files = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', '03aa6fc', 'assets/audio'], cwd=ROOT).decode().splitlines()
report = {}
for name in files:
    if not name.endswith('.wav'):
        continue
    dest = OUT / 'old_audio' / Path(name).name
    dest.write_bytes(subprocess.check_output(['git', 'show', f'03aa6fc:{name}'], cwd=ROOT))
    with wave.open(str(dest)) as w:
        assert w.getsampwidth() == 2
        samples = np.frombuffer(w.readframes(w.getnframes()), dtype='<i2').astype(float) / 32768
        peak = float(np.max(np.abs(samples)))
        rms = float(np.sqrt(np.mean(samples * samples)))
        report[dest.name] = {'seconds': w.getnframes() / w.getframerate(), 'channels': w.getnchannels(), 'sample_rate': w.getframerate(), 'peak_dbfs': round(20 * math.log10(max(peak, 1e-10)), 2), 'rms_dbfs': round(20 * math.log10(max(rms, 1e-10)), 2)}
for name in ['scenes/audio.tscn', 'scenes/battle_effect.tscn', 'scripts/audio_director.gd', 'scripts/battle_effect.gd', 'project.godot']:
    (OUT / ('old_' + Path(name).name + '.txt')).write_bytes(subprocess.check_output(['git', 'show', f'03aa6fc:{name}'], cwd=ROOT))
(OUT / 'file_levels.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
for name in ['audibility_baseline.gd', 'audibility_baseline.tscn']:
    shutil.copyfile(ROOT / 'tests' / name, OUT / name)
(OUT / 'project.godot').write_text('''config_version=5
[application]
config/name="Isolated audibility baseline"
run/main_scene="res://audibility_baseline.tscn"
[display]
window/size/viewport_width=160
window/size/viewport_height=120
window/size/initial_position_type=0
window/size/initial_position=Vector2i(-20000, -20000)
[rendering]
renderer/rendering_method="gl_compatibility"
''', encoding='utf-8')
print(json.dumps(report, indent=2))
