"""Собирает .ico из выбранного варианта знака (по умолчанию A) для окна, ярлыка,
установщика и состояний трея. Запуск: python tools/make-ico.py [A|B|C]"""
import os
import sys
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "assets", "proposals")
OUT_ASSETS = os.path.join(ROOT, "assets")
OUT_UI = os.path.join(ROOT, "ui", "assets")
os.makedirs(OUT_ASSETS, exist_ok=True)
os.makedirs(OUT_UI, exist_ok=True)

variant = (sys.argv[1] if len(sys.argv) > 1 else "A").upper()
base = Image.open(os.path.join(SRC, "icon-%s.png" % variant)).convert("RGBA")
SIZES = [16, 20, 24, 32, 48, 64, 128, 256]

app_ico = os.path.join(OUT_ASSETS, "mghelper.ico")
base.save(app_ico, format="ICO", sizes=[(s, s) for s in SIZES])
base.save(os.path.join(OUT_UI, "mghelper.ico"), format="ICO", sizes=[(s, s) for s in SIZES])

ACCENT = (59, 165, 93)
COLORS = {
    "green": (59, 165, 93),
    "gold": (217, 164, 65),
    "gray": (140, 150, 165),
    "red": (217, 83, 79),
}


def tray_icon(color):
    """Круг состояния + белый щит с шестерёнкой внутри (читается в 16–32 px)."""
    size = 256
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse([8, 8, size - 8, size - 8], fill=color + (255,))
    cx, cy, w, h = size / 2, size / 2 + 6, size * 0.42, size * 0.50
    left, right, top, bottom = cx - w / 2, cx + w / 2, cy - h / 2, cy + h / 2
    shield = [(left, top), (right, top), (right, top + h * 0.45), (cx, bottom), (left, top + h * 0.45)]
    d.polygon(shield, fill=(255, 255, 255, 235))
    r_in, r_out = size * 0.075, size * 0.115
    import math
    for i in range(6):
        ang = 2 * math.pi * i / 6
        tw, th = r_out * 0.5, (r_out - r_in) * 2.2
        x = cx + math.cos(ang) * (r_in + (r_out - r_in) / 2)
        y = cy + math.sin(ang) * (r_in + (r_out - r_in) / 2)
        pts = []
        for dx, dy in ((-tw / 2, -th / 2), (tw / 2, -th / 2), (tw / 2, th / 2), (-tw / 2, th / 2)):
            pts.append((x + dx * math.cos(ang) - dy * math.sin(ang), y + dx * math.sin(ang) + dy * math.cos(ang)))
        d.polygon(pts, fill=color + (255,))
    d.ellipse([cx - r_out, cy - r_out, cx + r_out, cy + r_out], fill=color + (255,))
    d.ellipse([cx - r_in, cy - r_in, cx + r_in, cy + r_in], fill=(255, 255, 255, 235))
    return img


for name, color in COLORS.items():
    icon = tray_icon(color)
    icon.save(os.path.join(OUT_UI, "tray-%s.ico" % name), format="ICO", sizes=[(16, 16), (24, 24), (32, 32), (48, 48)])
    icon.resize((64, 64), Image.LANCZOS).save(os.path.join(OUT_UI, "tray-%s.png" % name), "PNG")

print("variant", variant)
print("app icon:", app_ico, os.path.getsize(app_ico), "bytes")
for name in ("mghelper.ico", "tray-green.ico", "tray-gold.ico", "tray-gray.ico", "tray-red.ico"):
    p = os.path.join(OUT_UI, name)
    print("  ui/assets/%s %d bytes" % (name, os.path.getsize(p)))