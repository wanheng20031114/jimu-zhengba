"""Bounded real lobby/DTLS verification using an isolated local relay."""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import uuid

from network_game_live_runner import ROOT, local_server


def main() -> int:
    directory = ROOT / '.local/network' / ('lobby-room-' + uuid.uuid4().hex[:8])
    directory.mkdir(parents=True)
    project_name = re.search(r'config/name="([^"]+)"', (ROOT / 'project.godot').read_text(encoding='utf-8')).group(1)
    preferences = Path(os.environ['APPDATA']) / 'Godot/app_userdata' / project_name / 'lobby_preferences.cfg'
    original_preferences = preferences.read_bytes() if preferences.exists() else None
    children, handles = [], []
    result = 1
    try:
        endpoint = local_server(directory, children, handles)
        endpoint_file = directory / 'endpoint.json'
        endpoint_file.write_text(json.dumps(endpoint), encoding='utf-8')
        out = (directory / 'lobby.stdout.log').open('wb')
        err = (directory / 'lobby.stderr.log').open('wb')
        handles.extend((out, err))
        process = subprocess.Popen(
            [r'C:/Program Files/Godot/Godot.exe', '--headless', '--path', str(ROOT), '--script',
             'res://tests/lobby_room_live_test.gd', '--', str(endpoint_file)],
            stdout=out, stderr=err, creationflags=subprocess.CREATE_NO_WINDOW)
        children.append(process)
        result = process.wait(timeout=60)
    finally:
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
        for handle in handles:
            handle.close()
        if original_preferences is None:
            preferences.unlink(missing_ok=True)
        else:
            preferences.write_bytes(original_preferences)
        print('LOBBY_ROOM_OWNED_PROCESSES_EXITED', all(child.poll() is not None for child in children))
    stdout = (directory / 'lobby.stdout.log').read_text(encoding='utf-8', errors='replace')
    for line in stdout.splitlines():
        if line.startswith('LOBBY_ROOM_LIVE_RESULTS '):
            print(line)
    for filename in ('lobby.stderr.log', 'relay.stderr.log'):
        if (directory / filename).stat().st_size:
            print('LOBBY_ROOM_UNEXPECTED_STDERR', filename)
            result = 1
    print('LOBBY_ROOM_SUITE_EXIT', result)
    return result


if __name__ == '__main__':
    raise SystemExit(main())
