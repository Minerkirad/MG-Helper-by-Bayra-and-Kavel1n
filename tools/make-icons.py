"""Генерирует три варианта иконки MG Helper (256 px) и общий превью-лист."""
import os
from PIL import Image, ImageDraw, ImageFont

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets", "proposals")
os.makedirs(OUT, exist_ok=True)
S = 512          # рабочее разрешение
ACCENT = (59, 165, 93)
ACCENT_DARK = (32, 122, 69)
BG_DARK = (15, 17, 21)
WHITE = (245, 248, 252)

FONT_BOLD = r"C:\Windows\Fonts\segoeuib.ttf"
FONT_SEMI = r"C:\Windows\Fonts\seguisb.ttf"


def shield_points(cx, cy, w, h):
    """Контур щита: сверху прямые плечи, снизу скруглённое остриё."""
    left, right = cx - w / 2, cx + w / 2
    top, bottom = cy - h / 2, cy + h / 2
    return [
        (left, top), (cx, top), (right, top),
        (right, top + h * 0.45),
        (cx, bottom), (left, top + h * 0.45),
    ]


def rounded_bg(size, color, radius_ratio=0.22):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=int(size * radius_ratio), fill=color)
    return img


def gear(draw, cx, cy, r_out, r_in, teeth=8, color=WHITE):
    import math
    for i in range(teeth):
        ang = 2 * math.pi * i / teeth
        tw, th = r_out * 0.46, (r_out - r_in) * 1.9
        x = cx + math.cos(ang) * (r_in + (r_out - r_in) / 2)
        y = cy + math.sin(ang) * (r_in + (r_out - r_in) / 2)
        pts = []
        for dx, dy in ((-tw / 2, -th / 2), (tw / 2, -th / 2), (tw / 2, th / 2), (-tw / 2, th / 2)):
            rx = dx * math.cos(ang) - dy * math.sin(ang)
            ry = dx * math.sin(ang) + dy * math.cos(ang)
            pts.append((x + rx, y + ry))
        draw.polygon(pts, fill=color)
    draw.ellipse([cx - r_out, cy - r_out, cx + r_out, cy + r_out], fill=color)
    draw.ellipse([cx - r_in, cy - r_in, cx + r_in, cy + r_in], fill=None, outline=None)


def variant_a():
    """A: тёмный тайл, зелёный щит, белая шестерёнка."""
    img = rounded_bg(S, BG_DARK)
    d = ImageDraw.Draw(img)
    pad = S * 0.18
    w, h = S - 2 * pad, S - 2 * pad * 1.15
    cx, cy = S / 2, S / 2
    d.polygon(shield_points(cx, cy, w, h), fill=ACCENT)
    d.polygon(shield_points(cx, cy, w * 0.78, h * 0.80), fill=ACCENT_DARK)
    d.ellipse([cx - S * 0.20, cy - S * 0.20, cx + S * 0.20, cy + S * 0.20], fill=ACCENT)
    gear(d, cx, cy, S * 0.17, S * 0.085, 8, WHITE)
    return img


def variant_b():
    """B: прозрачный фон, зелёный щит с монограммой MG."""
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pad = S * 0.10
    cx, cy = S / 2, S / 2
    d.polygon(shield_points(cx, cy, S - 2 * pad, S - 2 * pad * 1.1), fill=ACCENT)
    d.polygon(shield_points(cx, cy, (S - 2 * pad) * 0.80, (S - 2 * pad * 1.1) * 0.80), fill=ACCENT_DARK)
    try:
        f = ImageFont.truetype(FONT_BOLD, int(S * 0.34))
        txt = "MG"
        box = d.textbbox((0, 0), txt, font=f)
        d.text((cx - (box[2] - box[0]) / 2 - box[0], cy - (box[3] - box[1]) / 2 - box[1] - S * 0.02), txt, font=f, fill=WHITE)
    except Exception:
        pass
    return img


def variant_c():
    """C: тёмный тайл, щит-контур и три «ползунка настроек»."""
    img = rounded_bg(S, BG_DARK)
    d = ImageDraw.Draw(img)
    pad = S * 0.16
    d.polygon(shield_points(S / 2, S / 2, S - 2 * pad, S - 2 * pad * 1.12), fill=ACCENT)
    inner = shield_points(S / 2, S / 2, (S - 2 * pad) * 0.74, (S - 2 * pad * 1.12) * 0.74)
    d.polygon(inner, fill=BG_DARK)
    xs = S * 0.36
    for i, y in enumerate((S * 0.42, S * 0.52, S * 0.62)):
        d.rounded_rectangle([xs, y - S * 0.012, S - xs, y + S * 0.012], radius=S * 0.012, fill=ACCENT)
        knob_x = xs + (S - 2 * xs) * (0.75 - 0.25 * i)
        r = S * 0.035
        d.ellipse([knob_x - r, y - r, knob_x + r, y + r], fill=WHITE)
    return img


def save(img, name, size=256):
    img.resize((size, size), Image.LANCZOS).save(os.path.join(OUT, name), "PNG")
    return img


variants = [
    ("A - щит + шестерёнка", variant_a()),
    ("B - щит + монограмма", variant_b()),
    ("C - щит + настройки", variant_c()),
]
for i, (title, img) in enumerate(variants):
    save(img, "icon-%s.png" % "ABC"[i])

# превью-лист: три варианта на тёмном фоне в размерах 128 и 32
sheet = Image.new("RGBA", (3 * 260, 360), BG_DARK + (255,))
d = ImageDraw.Draw(sheet)
try:
    label = ImageFont.truetype(FONT_SEMI, 18)
except Exception:
    label = ImageFont.load_default()
for i, (title, img) in enumerate(variants):
    big = img.resize((256, 256), Image.LANCZOS)
    sheet.alpha_composite(big, (i * 260, 10))
    d.text((i * 260 + 6, 276), title, font=label, fill=WHITE)
    small = img.resize((32, 32), Image.LANCZOS)
    sheet.alpha_composite(small, (i * 260 + 200, 300))
sheet.save(os.path.join(OUT, "preview.png"), "PNG")
print("ok", OUT)