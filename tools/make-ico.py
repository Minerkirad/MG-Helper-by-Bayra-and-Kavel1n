"""Иконки MG Helper 3.1: знак для окна/установщика и состояния трея.
Дизайн: щит с галочкой на акцентном фоне, толстые штрихи — читается с 16 px."""
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_ASSETS = os.path.join(ROOT, "assets")
OUT_UI = os.path.join(ROOT, "ui", "assets")
os.makedirs(OUT_ASSETS, exist_ok=True)
os.makedirs(OUT_UI, exist_ok=True)

SIZES = [16, 20, 24, 32, 48, 64, 128, 256]
ACCENT = (59, 165, 93)
ACCENT_DARK = (32, 122, 69)
TILE = (15, 17, 21)
WHITE = (247, 250, 252)


def shield(d, cx, cy, w, h, fill):
    left, right, top, bottom = cx - w / 2, cx + w / 2, cy - h / 2, cy + h / 2
    d.polygon([(left, top), (right, top), (right, top + h * 0.42), (cx, bottom), (left, top + h * 0.42)], fill=fill)


def check(d, cx, cy, s, color, width):
    """Галочка толстым штрихом — главный опознавательный знак."""
    d.line([(cx - s * 0.42, cy + s * 0.02), (cx - s * 0.10, cy + s * 0.34), (cx + s * 0.46, cy - s * 0.30)],
           fill=color, width=int(width), joint="curve")


def make_icon(size=512, tile=True, accent=ACCENT):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if tile:
        d.rounded_rectangle([0, 0, size - 1, size - 1], radius=int(size * 0.24), fill=TILE)
    # мягкое свечение акцента снизу
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([size * 0.10, size * 0.45, size * 0.90, size * 1.10], fill=accent + (60,))
    glow = glow.filter(__import__("PIL.ImageFilter", fromlist=["GaussianBlur"]).GaussianBlur(size * 0.08))
    img.alpha_composite(glow)
    d = ImageDraw.Draw(img)
    shield(d, size / 2, size * 0.50, size * 0.52, size * 0.58, accent)
    check(d, size / 2, size * 0.50, size * 0.30, TILE, max(3, size * 0.055))
    return img


app = make_icon()
app.save(os.path.join(OUT_ASSETS, "mghelper.ico"), format="ICO", sizes=[(s, s) for s in SIZES])
app.save(os.path.join(OUT_UI, "mghelper.ico"), format="ICO", sizes=[(s, s) for s in SIZES])
app.resize((256, 256), Image.LANCZOS).save(os.path.join(OUT_ASSETS, "icon-3.1.png"), "PNG")

STATES = {"green": (59, 165, 93), "gold": (217, 164, 65), "gray": (140, 150, 165), "red": (217, 83, 79)}
for name, color in STATES.items():
    size = 256
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # круглый бейдж: цветное кольцо + тёмный центр + щит с галочкой
    d.ellipse([6, 6, size - 6, size - 6], fill=TILE)
    d.ellipse([6, 6, size - 6, size - 6], outline=color, width=int(size * 0.085))
    shield(d, size / 2, size * 0.52, size * 0.50, size * 0.54, color)
    check(d, size / 2, size * 0.52, size * 0.28, TILE, int(size * 0.055))
    img.save(os.path.join(OUT_UI, "tray-%s.ico" % name), format="ICO", sizes=[(16, 16), (20, 20), (24, 24), (32, 32), (48, 48)])
    img.resize((64, 64), Image.LANCZOS).save(os.path.join(OUT_UI, "tray-%s.png" % name), "PNG")

# лист для просмотра: крупно + реальные размеры 16/24/32
sheet = Image.new("RGBA", (720, 300), TILE + (255,))
sheet.alpha_composite(app.resize((200, 200), Image.LANCZOS), (20, 40))
try:
    f = ImageFont.truetype(r"C:\Windows\Fonts\seguisb.ttf", 18)
except Exception:
    f = ImageFont.load_default()
dd = ImageDraw.Draw(sheet)
dd.text((20, 250), "иконка приложения", font=f, fill=WHITE)
x = 250
for name in ("green", "gold", "gray", "red"):
    ico = Image.open(os.path.join(OUT_UI, "tray-%s.png" % name)).convert("RGBA")
    sheet.alpha_composite(ico, (x, 30))
    for i, s in enumerate((16, 24, 32)):
        sheet.alpha_composite(ico.resize((s, s), Image.LANCZOS), (x + 6 + i * 40, 120))
    dd.text((x, 250), name, font=f, fill=WHITE)
    x += 115
sheet.save(os.path.join(OUT_ASSETS, "assets-preview.png"), "PNG")
print("ok")
for n in ("mghelper.ico", "tray-green.ico", "tray-gold.ico", "tray-gray.ico", "tray-red.ico"):
    print(n, os.path.getsize(os.path.join(OUT_UI, n)), "bytes")