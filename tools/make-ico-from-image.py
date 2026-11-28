"""Собирает .ico и состояния трея из готового изображения (assets/source-icon.png
или путь в первом аргументе). Кадрирует по содержимому, выравнивает в квадрат с полями,
генерирует мультиразмерный .ico и лист предпросмотра для проверки глазами.

    python tools/make-ico-from-image.py [путь-к-png]
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "assets", "source-icon.png")
OUT_ASSETS = os.path.join(ROOT, "assets")
OUT_UI = os.path.join(ROOT, "ui", "assets")
os.makedirs(OUT_ASSETS, exist_ok=True)
os.makedirs(OUT_UI, exist_ok=True)

SIZES = [16, 20, 24, 32, 48, 64, 128, 256]
TILE = (15, 17, 21)
WHITE = (247, 250, 252)

if not os.path.exists(SRC):
    raise SystemExit("нет исходника: " + SRC)

art = Image.open(SRC).convert("RGBA")
bbox = art.split()[-1].getbbox()
if bbox:
    art = art.crop(bbox)

# квадрат: содержимое по центру, поля 6% — вписывается и в круглые, и в квадратные слоты
side = int(max(art.size) * 1.12)
square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
square.alpha_composite(art, ((side - art.size[0]) // 2, (side - art.size[1]) // 2))


def for_size(size):
    """Для мелких размеров слегка повышаем резкость — иначе иконка 'мылится'."""
    img = square.resize((size, size), Image.LANCZOS)
    if size <= 32:
        img = img.filter(ImageFilter.UnsharpMask(radius=0.6, percent=110, threshold=1))
    return img


app = for_size(256)
app.save(os.path.join(OUT_ASSETS, "mghelper.ico"), format="ICO", sizes=[(s, s) for s in SIZES])
app.save(os.path.join(OUT_UI, "mghelper.ico"), format="ICO", sizes=[(s, s) for s in SIZES])
app.save(os.path.join(OUT_ASSETS, "icon-3.1.png"), "PNG")

# состояния трея: рисунок + цветной бейдж состояния в правом нижнем углу
STATES = {"green": (59, 165, 93), "gold": (224, 166, 60), "gray": (140, 150, 165), "red": (224, 85, 85)}
for name, color in STATES.items():
    for size in (16, 20, 24, 32, 48, 256):
        base = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        art_s = for_size(size)
        base.alpha_composite(art_s, (0, 0))
        d = ImageDraw.Draw(base)
        r = max(3, int(size * 0.30))
        cx, cy = size - r - 1, size - r - 1
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=TILE, outline=color, width=max(1, size // 12))
        if size >= 20:
            d.ellipse([cx - r // 2, cy - r // 2, cx + r // 2, cy + r // 2], fill=color)
        base.save(os.path.join(OUT_UI, "tray-%s-%d.png" % (name, size)), "PNG")
    # .ico из всех размеров сразу
    frames = [Image.open(os.path.join(OUT_UI, "tray-%s-%d.png" % (name, s))).convert("RGBA") for s in (16, 20, 24, 32, 48, 256)]
    frames[-1].save(os.path.join(OUT_UI, "tray-%s.ico" % name), format="ICO",
                    sizes=[(16, 16), (20, 20), (24, 24), (32, 32), (48, 48), (256, 256)])
    for s in (16, 20, 24, 32, 48):
        try:
            os.remove(os.path.join(OUT_UI, "tray-%s-%d.png" % (name, s)))
        except OSError:
            pass

# лист предпросмотра: как выглядит в реальных размерах
sheet = Image.new("RGBA", (760, 300), TILE + (255,))
dd = ImageDraw.Draw(sheet)
try:
    f = ImageFont.truetype(r"C:\Windows\Fonts\seguisb.ttf", 16)
except Exception:
    f = ImageFont.load_default()
sheet.alpha_composite(for_size(200), (24, 30))
dd.text((24, 244), "app icon 200 px", font=f, fill=WHITE)
x = 260
for i, s in enumerate((16, 24, 32, 48, 64)):
    sheet.alpha_composite(for_size(s), (x, 60))
    dd.text((x - 2, 120), str(s), font=f, fill=WHITE)
    x += s + 22
x = 260
for name in ("green", "gold", "gray", "red"):
    ico = Image.open(os.path.join(OUT_UI, "tray-%s.ico" % name)).convert("RGBA")
    sheet.alpha_composite(ico.resize((32, 32), Image.LANCZOS), (x, 170))
    dd.text((x - 2, 210), name, font=f, fill=WHITE)
    x += 92
sheet.save(os.path.join(OUT_ASSETS, "assets-preview.png"), "PNG")

print("source:", SRC, art.size, "-> square", (side, side))
for n in ("mghelper.ico", "tray-green.ico", "tray-gold.ico", "tray-gray.ico", "tray-red.ico"):
    print("  ui/assets/%-18s %6d bytes" % (n, os.path.getsize(os.path.join(OUT_UI, n))))
print("  assets/mghelper.ico    %6d bytes" % os.path.getsize(os.path.join(OUT_ASSETS, "mghelper.ico")))
print("  assets/assets-preview.png (для проверки глазами)")