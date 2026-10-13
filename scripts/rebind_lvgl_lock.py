#!/usr/bin/env python3
"""Rebind only the local LVGL lock path after moving this source checkout."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
lock = root / 'platforms/esp32/dependencies.lock'
path = root / 'third_party/lvgl'
if not (path / 'lvgl.h').is_file():
    raise SystemExit('LVGL checkout missing; initialize the existing submodule first.')
text = lock.read_text()
updated, count = re.subn(r'(?m)^      path: .*third_party/lvgl$',
                         lambda _: f'      path: {path}', text)
if count != 1:
    raise SystemExit('Expected exactly one local LVGL lock entry; no changes made.')
if updated != text:
    lock.write_text(updated)
print(f'LVGL local source: {path}')
