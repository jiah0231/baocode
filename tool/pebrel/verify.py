#!/usr/bin/env python3
"""Offline asset checks; not a substitute for the Dart/Flutter tests."""
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
root = Path(__file__).resolve().parents[2]
path = root/'assets/pebrel/catalog.json'
before = path.read_bytes()
subprocess.run([sys.executable, str(root/'tool/pebrel/generate.py')], check=True)
assert before == path.read_bytes(), 'catalog not generated from pinned sources'
themes = json.loads(before)['themes']
assert len(themes) == 16
assert len({t['name'] for t in themes}) == 16
for theme in themes:
    terminal = theme['terminal']
    assert len(terminal['palette']) == 256
    assert all(re.fullmatch('#[0-9A-F]{6}', c) for c in terminal['palette'])
    assert terminal['palette'][16] == '#000000'
    assert terminal['palette'][255] == '#EEEEEE'
    assert all(k in theme for k in ('typography', 'layout', 'effects'))
macchiato = next(t for t in themes if t['base'] == 'CatppuccinMacchiato')
assert macchiato['terminal']['palette'][1] == '#ED8796'
assert macchiato['terminal']['palette'][9] == '#EC7486'
assert macchiato['ui']['background'] == '#24273A'
assert macchiato['ui']['shell'] == '#1E2030'
for base in ['SilverLight', 'LimestoneLight', 'LinenLight']:
    terminal = next(t['terminal'] for t in themes if t['base'] == base)
    assert terminal['background'] == '#FFFFFF'
    assert terminal['foreground'] == '#24292F'
    assert terminal['cursor'] is None
assert next(t['terminal']['cursor'] for t in themes if t['base'] == 'WarmSand') is None
print('PASS: 16 themes, 4096 indexed colors, deterministic source regeneration, exact Macchiato and independent legacy terminal data')
print('Catalog SHA256:', hashlib.sha256(before).hexdigest())
