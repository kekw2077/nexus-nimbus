"""Генератор системной графики Nexus Nimbus.

Рисует иконку приложения и картинки мастера установки из тех же токенов, что
и интерфейс: фон #07080C, акцент «Аврора» (#1CACC2 → #3F63D1 → #8A6FD4),
сетка точек с шагом 15 px.

    python assets/icon/gen_icon.py

На выходе:
    windows/runner/resources/app_icon.ico   иконка exe, ярлыка и установщика
    assets/icon/app_icon.png                512 px, для README и витрин
    dist/wizard-banner.bmp                  164×314, боковая полоса мастера
    dist/wizard-small.bmp                   55×55, значок в шапке мастера
    dist/btn_primary.bmp                    подложка главной кнопки мастера
    dist/btn_quiet.bmp                      подложка второстепенной кнопки

Иконка временная: положите свою в windows/runner/resources/app_icon.ico и
скрипт больше не нужен. Картинки мастера он всё равно пересоберёт из неё же —
см. --from-icon.
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]

BG = (7, 8, 12)
A1 = (28, 172, 194)
A2 = (63, 99, 209)
A3 = (138, 111, 212)
DOT = (255, 255, 255, 82)

# Рисуем всё крупно и уменьшаем — так края выходят гладкими без сглаживания
# вручную. Множитель 4 достаточен и не съедает память на 256 px.
SS = 4


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def accent_at(t: float):
    """Точка градиента 0..1 по трём опорным цветам, стопы 0 / .55 / 1."""
    t = max(0.0, min(1.0, t))
    if t <= 0.55:
        return lerp(A1, A2, t / 0.55)
    return lerp(A2, A3, (t - 0.55) / 0.45)


def gradient(size, angle_deg=140.0, alpha=255):
    """Линейный градиент под углом, как linear-gradient(140deg, …) в прототипе."""
    w, h = size
    img = Image.new("RGBA", size)
    px = img.load()
    rad = math.radians(angle_deg)
    dx, dy = math.cos(rad), math.sin(rad)
    # Нормируем проекцию так, чтобы 0 и 1 приходились на противоположные углы.
    span = abs(dx) * w + abs(dy) * h
    base = (w if dx < 0 else 0) * abs(dx) + (h if dy < 0 else 0) * abs(dy)
    for y in range(h):
        for x in range(w):
            t = (x * dx + y * dy + base) / span
            px[x, y] = accent_at(t) + (alpha,)
    return img


def rounded_mask(size, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius, fill=255)
    return mask


def cloud_mask(size, inset=0.14):
    """Облако: три круга и прямоугольное основание, всё в одной маске."""
    w, h = size
    m = Image.new("L", size, 0)
    d = ImageDraw.Draw(m)

    pad = w * inset
    cw = w - pad * 2
    ch = cw * 0.62
    x0 = pad
    y0 = (h - ch) / 2 + ch * 0.10

    # Основание — скруглённая полоса по низу облака.
    base_h = ch * 0.42
    d.rounded_rectangle(
        [x0, y0 + ch - base_h, x0 + cw, y0 + ch], radius=base_h / 2, fill=255
    )
    # Три пузыря: большой посередине, поменьше по бокам.
    d.ellipse([x0, y0 + ch * 0.34, x0 + cw * 0.44, y0 + ch], fill=255)
    d.ellipse([x0 + cw * 0.20, y0, x0 + cw * 0.76, y0 + ch * 0.86], fill=255)
    d.ellipse([x0 + cw * 0.58, y0 + ch * 0.26, x0 + cw, y0 + ch * 0.98], fill=255)
    return m


def dot_grid(size, step=15, radius=1.1, color=DOT):
    """Сетка точек прототипа. Шаг задаётся в конечных пикселях."""
    img = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for y in range(step // 2, size[1], step):
        for x in range(step // 2, size[0], step):
            d.ellipse([x - radius, y - radius, x + radius, y + radius], fill=color)
    return img


def make_icon(px: int) -> Image.Image:
    """Знак: скруглённый квадрат с акцентным градиентом и белым облаком."""
    s = px * SS
    tile = gradient((s, s))
    tile.putalpha(rounded_mask((s, s), int(s * 0.22)))

    # Мягкий блик сверху слева — тот же приём, что у кнопок в интерфейсе.
    glow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse(
        [-s * 0.35, -s * 0.55, s * 0.75, s * 0.45], fill=(255, 255, 255, 46)
    )
    glow = glow.filter(ImageFilter.GaussianBlur(s * 0.10))
    glow.putalpha(Image.composite(glow.getchannel("A"), Image.new("L", (s, s), 0),
                                  rounded_mask((s, s), int(s * 0.22))))
    tile = Image.alpha_composite(tile, glow)

    cloud = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    cloud.putalpha(cloud_mask((s, s)))
    white = Image.new("RGBA", (s, s), (255, 255, 255, 255))
    white.putalpha(cloud.getchannel("A"))
    tile = Image.alpha_composite(tile, white)

    return tile.resize((px, px), Image.LANCZOS)


def make_banner(icon: Image.Image) -> Image.Image:
    """Боковая полоса мастера 164×314: тёмный фон, аврора снизу, знак сверху."""
    w, h = 164, 314
    img = Image.new("RGB", (w, h), BG)

    # Аврора: три размытых пятна у нижнего края, как NxBackgroundLayer.
    blobs = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(blobs)
    for cx, cy, r, color in (
        (w * 0.18, h * 1.02, w * 0.62, A1),
        (w * 0.86, h * 1.06, w * 0.66, A2),
        (w * 0.52, h * 1.18, w * 0.52, A3),
    ):
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=color + (150,))
    blobs = blobs.filter(ImageFilter.GaussianBlur(30))
    img = Image.alpha_composite(img.convert("RGBA"), blobs)
    img = Image.alpha_composite(img, dot_grid((w, h)))

    badge = icon.resize((54, 54), Image.LANCZOS)
    img.alpha_composite(badge, (20, 26))

    d = ImageDraw.Draw(img)
    d.line([(w - 1, 0), (w - 1, h)], fill=(255, 255, 255, 24))
    return img.convert("RGB")


def make_small(icon: Image.Image) -> Image.Image:
    """Значок в шапке 55×55 на фоне полосы шапки."""
    img = Image.new("RGB", (55, 55), BG)
    img = img.convert("RGBA")
    img.alpha_composite(icon.resize((37, 37), Image.LANCZOS), (9, 9))
    return img.convert("RGB")


def make_button(size, primary: bool) -> Image.Image:
    """Подложка кнопки мастера: акцентная заливка либо тихая плашка."""
    w, h = size
    s = (w * SS, h * SS)
    if primary:
        img = gradient(s, angle_deg=96.0)
    else:
        img = Image.new("RGBA", s, (255, 255, 255, 16))
        ImageDraw.Draw(img).rounded_rectangle(
            [0, 0, s[0] - 1, s[1] - 1], radius=s[1] // 2,
            outline=(255, 255, 255, 46), width=SS,
        )
    img.putalpha(
        Image.composite(img.getchannel("A"), Image.new("L", s, 0),
                        rounded_mask(s, s[1] // 2))
    )
    img = img.resize((w, h), Image.LANCZOS)

    # Inno показывает BMP без альфы, поэтому кладём кнопку на фон окна.
    flat = Image.new("RGBA", (w, h), BG + (255,))
    return Image.alpha_composite(flat, img).convert("RGB")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--from-icon",
        metavar="PATH",
        help="взять готовую иконку вместо рисованной (png или ico)",
    )
    ap.add_argument(
        "--wizard-only",
        action="store_true",
        help="не трогать app_icon.ico, пересобрать только графику мастера",
    )
    args = ap.parse_args()

    icons = ROOT / "windows" / "runner" / "resources"
    assets = ROOT / "assets" / "icon"
    dist = ROOT / "dist"
    for p in (icons, assets, dist):
        p.mkdir(parents=True, exist_ok=True)

    if args.from_icon:
        master = Image.open(args.from_icon).convert("RGBA")
        if master.size != (512, 512):
            master = master.resize((512, 512), Image.LANCZOS)
    else:
        master = make_icon(512)

    if not args.wizard_only:
        sizes = [16, 24, 32, 48, 64, 128, 256]
        master.save(
            icons / "app_icon.ico",
            format="ICO",
            sizes=[(s, s) for s in sizes],
        )
        master.save(assets / "app_icon.png", format="PNG")
        print("иконка:", icons / "app_icon.ico")

    make_banner(master).save(dist / "wizard-banner.bmp", format="BMP")
    make_small(master).save(dist / "wizard-small.bmp", format="BMP")
    make_button((110, 34), primary=True).save(dist / "btn_primary.bmp", format="BMP")
    make_button((110, 34), primary=False).save(dist / "btn_quiet.bmp", format="BMP")
    print("графика мастера:", dist)


if __name__ == "__main__":
    main()
