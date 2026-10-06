#!/usr/bin/env python3
"""Build fixed-layout typography comparisons from the Stage C LVGL captures.

Candidate Latin fonts and the Noto Sans SC fallback are rasterized at their
target pixel size and composited over identical captured page geometry.
This isolates typeface shape/weight; it is a host proof, not firmware output.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import sys
import json

repo = Path(__file__).resolve().parents[1]
base = repo / "docs/ui/stage-c-typography-polish"
font_dir = Path(sys.argv[1])
out = repo / "docs/ui/typography-candidates"
out.mkdir(parents=True, exist_ok=True)

schemes = {
    "Typography-A-Inter": {
        "hero": font_dir / "A-Inter-Semibold.ttf",
        "primary": font_dir / "A-Inter-Semibold.ttf",
        "secondary": font_dir / "A-Inter-Medium.ttf",
    },
    "Typography-B-RobotoCondensed": {
        "hero": font_dir / "B-RobotoCondensed-Bold.ttf",
        "primary": font_dir / "B-RobotoCondensed-Semibold.ttf",
        "secondary": font_dir / "B-RobotoCondensed-Medium.ttf",
    },
    "Typography-C-IBMPlex": {
        "hero": font_dir / "C-IBMPlex-Semibold.ttf",
        "primary": font_dir / "C-IBMPlex-Semibold.ttf",
        "secondary": font_dir / "C-IBMPlex-Medium.ttf",
    },
}
cjk = font_dir / "NotoSansSC-Medium.ttf"
WHITE, MUTED, ICE = "#F4F5EF", "#A2AAAC", "#A5F1F0"

def font(path, size):
    return ImageFont.truetype(str(path), size)

def centered(draw, text, xy, face, fill=WHITE, anchor="mm"):
    box = draw.textbbox((0, 0), text, font=face, anchor=anchor)
    width = box[2] - box[0]
    y = xy[1]
    radius = 232
    safe_width = 2 * max(0, (radius * radius - (y - 232) ** 2) ** 0.5) - 24
    if width > safe_width:
        raise ValueError(f"text exceeds circular safe width at {xy}: {text!r} ({width:.1f}>{safe_width:.1f})")
    draw.text(xy, text, font=face, fill=fill, anchor=anchor, stroke_width=0)

def mixed_center(draw, parts, xy, latin, chinese, fill=WHITE, check_circle=True):
    widths = []
    for run, is_cjk in parts:
        widths.append(draw.textlength(run, font=chinese if is_cjk else latin))
    total = sum(widths)
    if check_circle:
        radius = 232
        safe_width = 2 * max(0, (radius * radius - (xy[1] - 232) ** 2) ** 0.5) - 24
        if total > safe_width:
            raise ValueError(f"mixed text exceeds circular safe width at {xy}: {total:.1f}>{safe_width:.1f}")
    x = xy[0] - total / 2
    for (run, is_cjk), width in zip(parts, widths):
        draw.text((x, xy[1]), run, font=chinese if is_cjk else latin,
                  fill=fill, anchor="lm")
        x += width

def open_base(name):
    return Image.open(base / name).convert("RGB")

def clear(img, box):
    ImageDraw.Draw(img).rectangle(box, fill="#000000")

def mask_speed(img):
    clear(img, (135, 185, 330, 280))
    clear(img, (180, 275, 290, 311))

def patch_variant(scheme, key, img, state):
    latin = schemes[scheme]
    d = ImageDraw.Draw(img)
    if state in ("speed-48", "speed-108", "speed-unknown"):
        mask_speed(img)
        value = {"speed-48": "48", "speed-108": "108", "speed-unknown": "--"}[state]
        centered(d, value, (233, 235), font(latin["hero"], 96))
        centered(d, "km/h", (233, 293), font(latin["secondary"], 20), MUTED)
    elif state in ("nav-320", "nav-1_2km", "nav-chinese"):
        clear(img, (194, 43, 385, 149))
        clear(img, (224, 122, 337, 156))
        value, unit = ("320", "m") if state != "nav-1_2km" else ("1.2", "km")
        centered(d, value, (290, 87), font(latin["hero"], 56))
        centered(d, unit, (290, 137), font(latin["secondary"], 20), MUTED)
        clear(img, (153, 350, 313, 395))
        road = "星湖街" if state == "nav-chinese" else "建国路"
        centered(d, road, (233, 373), font(cjk, 28), WHITE)
    elif state == "compass":
        clear(img, (130, 110, 335, 229))
        centered(d, "045°", (233, 143), font(latin["hero"], 56), WHITE)
        centered(d, "NE", (233, 203), font(latin["primary"], 36), ICE)
    elif state in ("media-en", "media-mixed"):
        clear(img, (80, 174, 386, 231))
        clear(img, (90, 248, 376, 284))
        if state == "media-en":
            centered(d, "Nightcall", (233, 202), font(latin["primary"], 28))
        else:
            mixed_center(d, [("星湖街", True), (" City Lights", False)],
                         (233, 202), font(latin["primary"], 28), font(cjk, 28))
        centered(d, "Kavinsky", (233, 266), font(latin["secondary"], 20), MUTED)
    elif state in ("ready", "disconnected"):
        clear(img, (70, 285, 396, 349))
        label = "READY" if state == "ready" else "DISCONNECTED"
        centered(d, label, (233, 312), font(latin["primary"], 32),
                 ICE if state == "ready" else WHITE)
    return img

items = [
    ("speed-48", "speed-48-kmh.png", "Speed 48"),
    ("speed-108", "speed-108-kmh.png", "Speed 108"),
    ("nav-320", "navigation-normal.png", "Navigation 320 m"),
    ("nav-1_2km", "navigation-long-text-km.png", "Navigation 1.2 km"),
    ("nav-chinese", "navigation-normal.png", "Navigation 星湖街"),
    ("compass", "compass.png", "Compass NE / 045°"),
    ("media-en", "media-playing.png", "Media English"),
    ("media-mixed", "media-chinese-mixed.png", "Media 中英混排"),
    ("ready", "idle-ready.png", "READY"),
    ("disconnected", "disconnected.png", "DISCONNECTED"),
]

generated = {}
for scheme, cfg in schemes.items():
    folder = out / scheme
    folder.mkdir(parents=True, exist_ok=True)
    panels = []
    for key, original, title in items:
        background = "navigation-normal.png" if key == "nav-1_2km" else original
        img = patch_variant(scheme, key, open_base(background), key)
        img.save(folder / f"{key}.png")
        panels.append((img, title))
    sheet = Image.new("RGB", (1000, 1390), "#181B1D")
    draw = ImageDraw.Draw(sheet)
    for idx, (img, title) in enumerate(panels):
        col, row = idx % 2, idx // 2
        x, y = col * 500, row * 278
        sheet.paste(img.resize((250, 250), Image.Resampling.LANCZOS), (x + 15, y))
        draw.text((x + 275, y + 30), title, fill=WHITE, font=font(cfg["primary"], 20))
        draw.text((x + 275, y + 65), scheme.replace("Typography-", ""),
                  fill=MUTED, font=font(cfg["secondary"], 15))
    sheet.save(folder / "contact-sheet.png")
    sheet.save(out / f"{scheme}.png")
    generated[scheme] = panels

# Combined sheet: each row is one requested page; columns A/B/C share geometry.
combined = Image.new("RGB", (960, 10 * 260), "#181B1D")
draw = ImageDraw.Draw(combined)
for row, (key, _, title) in enumerate(items):
    for col, scheme in enumerate(schemes):
        background = "navigation-normal.png" if key == "nav-1_2km" else items[row][1]
        img = open_base(background)
        img = patch_variant(scheme, key, img, key)
        x, y = col * 320, row * 260
        combined.paste(img.resize((220, 220), Image.Resampling.LANCZOS), (x + 50, y + 30))
    draw.text((12, row * 260 + 5), title, fill=MUTED, font=font(next(iter(schemes.values()))["secondary"], 16))
combined.save(out / "Typography-A-B-C-Comparison.png")

# Check the requested Chinese fallback strings at their nominal small-screen
# pixel size, including the longer state labels and a mixed Latin/Chinese line.
samples = ["星湖街", "正在重新规划", "已到达", "手机已断开"]
sample = Image.new("RGB", (1600, 520), "#181B1D")
sd = ImageDraw.Draw(sample)
for row, text in enumerate(samples):
    y = 28 + row * 122
    sd.text((24, y), text, font=font(cjk, 28), fill=WHITE, anchor="lm")
    for col, scheme in enumerate(schemes):
        face = font(schemes[scheme]["primary"], 22)
        mixed_center(sd, [(text, True), ("  Waymate", False)],
                     (580 + col * 400, y), face, font(cjk, 28), WHITE,
                     check_circle=False)
sample.save(out / "Chinese-Fallback-Samples.png")
manifest = {
    "purpose": "Typography candidates only; does not alter firmware font selection",
    "base": "docs/ui/stage-c-typography-polish Stage C LVGL capture",
    "canvas_px": [466, 466],
    "rasterizer": "Pillow/FreeType, direct target-size font instances",
    "circle_safe_width_check": "all candidate text runs checked against circular chord with 12 px inset",
    "schemes": {
        "Typography-A-Inter": {"hero": 600, "primary": 600, "secondary": 500},
        "Typography-B-RobotoCondensed": {"hero": 700, "primary": 600, "secondary": 500},
        "Typography-C-IBMPlex": {"hero": 600, "primary": 600, "secondary": 500},
    },
    "pages": [title for _, _, title in items],
    "previews": [f"{name}.png" for name in schemes]
                 + ["Typography-A-B-C-Comparison.png", "Chinese-Fallback-Samples.png"],
}
(out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
print(f"Wrote comparison previews to {out}")
