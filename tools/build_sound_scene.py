"""Author bounded native audio voices, shared event resources and mix buses."""
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[1]
# count, player gain, bus, priority, minimum event gap (ms), concurrent instances
EVENTS = {
    'sword_swing': (3, -5, 'Combat', 2, 85, 3),
    'sword_hit': (4, -2, 'Combat', 3, 75, 4),
    'bow_release': (3, -3, 'Combat', 2, 110, 3),
    'arrow_hit': (3, -4, 'Combat', 2, 90, 3),
    'wood_hit': (3, -3, 'Combat', 2, 110, 3),
    'catapult_release': (2, -1, 'Combat', 4, 220, 2),
    'stone_hit': (3, -1, 'Combat', 4, 150, 3),
    'stone_chip': (3, -9, 'Combat', 2, 110, 3),
    'cannon_shot': (2, -2, 'Combat', 5, 160, 3),
    'explosion': (2, -2, 'Combat', 5, 180, 3),
    'collapse': (2, -1, 'Combat', 6, 350, 2),
    'death_fall': (3, -5, 'Combat', 2, 160, 3),
    'footstep_dirt': (4, 1, 'Foley', 1, 95, 3),
    'horse_hoof': (4, 2, 'Foley', 2, 120, 3),
    'cart_wheel': (3, -7, 'Foley', 1, 220, 2),
    'select': (2, -1, 'UI', 2, 130, 2),
    'order': (2, -1, 'UI', 2, 220, 2),
    'recruit': (2, -1, 'UI', 3, 160, 2),
    'denied': (2, -2, 'UI', 3, 450, 1),
    'coin': (3, -2, 'UI', 2, 180, 2),
    'victory': (1, -1, 'UI', 5, 1000, 1),
    'defeat': (1, -1, 'UI', 5, 1000, 1),
}


def build():
    lines = ['extends RefCounted', '## Shared audio resources; no runtime directory scan or per-unit duplication.', '', 'const EVENTS: Dictionary = {']
    for kind, (count, gain, bus, priority, gap, limit) in EVENTS.items():
        stem = 'ui_' + kind if kind in ('select', 'order', 'recruit', 'denied') else ('stone_hit' if kind == 'stone_chip' else kind)
        paths = [f'assets/audio/{stem}.wav'] if kind in ('victory', 'defeat') else [f'assets/audio/{stem}_{i:02}.wav' for i in range(1, count + 1)]
        for path in paths:
            if not (ROOT / path).is_file():
                raise FileNotFoundError(path)
        streams = ', '.join(f'preload("res://{path}")' for path in paths)
        lines.append(f'\t"{kind}": {{"streams": [{streams}], "gain_db": {float(gain)}, "bus": &"{bus}", "priority": {priority}, "gap_ms": {gap}, "limit": {limit}}},')
    lines.append('}\n')
    (ROOT / 'scripts/sound_bank.gd').write_text('\n'.join(lines), encoding='utf-8')

    scene = ['[gd_scene load_steps=2 format=3]', '', '[ext_resource type="Script" path="res://scripts/audio_director.gd" id="script"]', '', '[node name="Audio" type="Node"]', 'script = ExtResource("script")', 'process_mode = 3']
    for branch, amount, node_type in [('UI', 6, 'AudioStreamPlayer'), ('Combat', 24, 'AudioStreamPlayer3D'), ('Foley', 8, 'AudioStreamPlayer3D')]:
        scene.extend(['', f'[node name="{branch}" type="Node" parent="."]'])
        if branch != 'UI':
            # Native pause also holds 3D play() requests awaiting their first
            # physics frame; stream_paused alone only affects registered streams.
            scene.append('process_mode = 1')
        for index in range(amount):
            scene.extend(['', f'[node name="Voice{index:02}" type="{node_type}" parent="{branch}"]', f'bus = &"{branch}"', 'max_polyphony = 1'])
            if node_type.endswith('3D'):
                # Linear native distance falloff avoids inverse-distance near-field
                # amplification flattening authored per-event mix gains at max_db.
                scene.extend(['attenuation_model = 3', 'max_db = 0.0', 'max_distance = 64.0', 'panning_strength = 0.7', 'attenuation_filter_cutoff_hz = 14000.0', 'attenuation_filter_db = -6.0'])
    (ROOT / 'scenes/audio.tscn').write_text('\n'.join(scene) + '\n', encoding='utf-8')

    layout = '''[gd_resource type="AudioBusLayout" load_steps=3 format=3]

[sub_resource type="AudioEffectHardLimiter" id="master_limiter"]
resource_name = "Peak ceiling -1 dB"
ceiling_db = -1.0
pre_gain_db = 0.0
release = 0.12

[sub_resource type="AudioEffectCompressor" id="combat_compressor"]
resource_name = "Crowd dynamics"
threshold = -16.0
ratio = 2.5
attack_us = 2000.0
release_ms = 160.0
gain = 0.0
mix = 0.7

[resource]
bus/0/name = &"Master"
bus/0/volume_db = -1.411621
bus/0/mute = false
bus/0/effect/0/effect = SubResource("master_limiter")
bus/0/effect/0/enabled = true
bus/1/name = &"UI"
bus/1/send = &"Master"
bus/1/volume_db = 0.0
bus/2/name = &"Combat"
bus/2/send = &"Master"
bus/2/volume_db = 0.0
bus/2/effect/0/effect = SubResource("combat_compressor")
bus/2/effect/0/enabled = true
bus/3/name = &"Foley"
bus/3/send = &"Master"
bus/3/volume_db = -2.0
'''
    (ROOT / 'default_bus_layout.tres').write_text(layout, encoding='utf-8')
    print(json.dumps({'events': len(EVENTS), 'voices': {'UI': 6, 'Combat': 24, 'Foley': 8}, 'bgm': False}))


if __name__ == '__main__':
    build()
