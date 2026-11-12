"""生成 iOS AppIcon（1024，无 alpha）。用法: py tools/make_icon.py"""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "ios" / "Sources" / "Assets.xcassets" / "AppIcon.appiconset" / "icon-1024.png"
OUT.parent.mkdir(parents=True, exist_ok=True)

S = 1024
img = Image.new("RGB", (S, S), (76, 139, 245))
draw = ImageDraw.Draw(img)

# 渐变底
for y in range(S):
    t = y / (S - 1)
    draw.line([(0, y), (S, y)], fill=(
        int(76 + (32 - 76) * t),
        int(139 + (92 - 139) * t),
        int(245 + (210 - 245) * t),
    ))

u = S / 100
# 云（白色）
white = (255, 255, 255)
draw.rounded_rectangle([16 * u, 46 * u, 84 * u, 76 * u], radius=15 * u, fill=white)
draw.ellipse([22 * u, 30 * u, 52 * u, 60 * u], fill=white)
draw.ellipse([40 * u, 22 * u, 78 * u, 60 * u], fill=white)

# 向下的箭头（挖空成蓝色）
blue = (47, 106, 217)
draw.polygon([
    (45 * u, 40 * u), (55 * u, 40 * u), (55 * u, 56 * u), (64 * u, 56 * u),
    (50 * u, 72 * u), (36 * u, 56 * u), (45 * u, 56 * u),
], fill=blue)

img.save(OUT, "PNG")
print("icon ->", OUT, OUT.stat().st_size, "bytes")
