#!/usr/bin/env python3
"""Convert native LVGL test PPMs into nominal 466px circular review images.

Requires the existing Pillow installation. No production data is generated.
Usage: python3 scripts/render_round_display_previews.py INPUT_PPM_DIR OUTPUT_DIR
"""
import json
import sys
from pathlib import Path
from PIL import Image, ImageDraw

source, output = map(Path, sys.argv[1:3])
sheet_name = sys.argv[3] if len(sys.argv) > 3 else 'contact-sheet.png'
frames = sorted(source.glob('*.ppm'))
if not frames:
    raise SystemExit('No native framebuffer previews found')
output.mkdir(parents=True, exist_ok=True)
background = '#181B1D'
sheet = Image.new('RGB', (1280, 350 * ((len(frames) + 3) // 4)), background)
for index, path in enumerate(frames):
    frame = Image.open(path).convert('RGB')
    if frame.size != (466, 466):
        raise SystemExit(f'{path}: expected the production 466x466 canvas')
    mask = Image.new('L', frame.size)
    ImageDraw.Draw(mask).ellipse((0, 0, 465, 465), fill=255)
    circular = Image.new('RGB', frame.size, background)
    circular.paste(frame, (0, 0), mask)
    circular.save(output / f'{path.stem}.png')
    x, y = (index % 4) * 320, (index // 4) * 350
    sheet.paste(circular.resize((300, 300)), (x + 10, y))
    ImageDraw.Draw(sheet).text((x + 8, y + 307), path.stem, fill='white')
sheet.save(output / sheet_name)
(output / 'index.json').write_text(json.dumps({
    'source': 'tests/native/nav_ui_render_tests.cpp::test_stage_c_product_states',
    'renderer': 'real shared/nav_ui LVGL RGB565 framebuffer; test fixtures only',
    'size': [466, 466],
    'clipping': 'nominal circle mask; hardware optical/touch acceptance remains',
    'frames': [f'{p.stem}.png' for p in frames],
    'contact_sheet': sheet_name,
}, ensure_ascii=False, indent=2) + '\n')
print(f'Wrote {len(frames)} circular previews and {sheet_name}')
