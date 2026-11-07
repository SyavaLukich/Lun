#!/usr/bin/env python3
"""Генератор текстур для мода smart_npc.

Рисует скины 64x32 в классической раскладке (как character.b3d / npc.b3d),
а также мелкие иконки для частиц и предмета-призывателя.

Запуск из каталога мода:
    python3 tools/gen_textures.py

Требуется Pillow. Скрипт детерминированный: повторный запуск даёт те же файлы.
"""

import os
import random

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
TEX = os.path.join(HERE, "..", "textures")

# Раскладка классического скина 64x32 (регионы "лицо" кубиков).
HEAD = {
    "top": (8, 0, 8, 8),
    "bottom": (16, 0, 8, 8),
    "right": (0, 8, 8, 8),
    "front": (8, 8, 8, 8),
    "left": (16, 8, 8, 8),
    "back": (24, 8, 8, 8),
}
BODY = {
    "top": (20, 16, 8, 4),
    "bottom": (28, 16, 8, 4),
    "right": (16, 20, 4, 12),
    "front": (20, 20, 8, 12),
    "left": (28, 20, 4, 12),
    "back": (32, 20, 8, 12),
}
ARM = {
    "top": (44, 16, 4, 4),
    "bottom": (48, 16, 4, 4),
    "right": (40, 20, 4, 12),
    "front": (44, 20, 4, 12),
    "left": (48, 20, 4, 12),
    "back": (52, 20, 4, 12),
}
LEG = {
    "top": (4, 16, 4, 4),
    "bottom": (8, 16, 4, 4),
    "right": (0, 20, 4, 12),
    "front": (4, 20, 4, 12),
    "left": (8, 20, 4, 12),
    "back": (12, 20, 4, 12),
}

PALETTES = [
    # кожа, волосы, рубашка, штаны, обувь
    ((232, 190, 152), (74, 45, 30), (86, 132, 176), (58, 62, 74), (44, 38, 34)),
    ((206, 156, 116), (24, 22, 24), (176, 82, 66), (52, 54, 60), (36, 32, 30)),
    ((244, 208, 172), (152, 96, 48), (98, 148, 96), (74, 66, 54), (48, 40, 32)),
    ((188, 132, 92), (40, 30, 26), (204, 178, 92), (60, 70, 92), (38, 34, 32)),
    ((238, 196, 160), (110, 66, 40), (146, 104, 168), (66, 60, 78), (42, 38, 40)),
    ((222, 174, 132), (196, 176, 132), (92, 116, 148), (90, 78, 62), (52, 44, 36)),
    ((250, 214, 178), (176, 112, 52), (198, 120, 84), (58, 84, 106), (40, 36, 34)),
    ((200, 148, 108), (60, 42, 34), (176, 176, 184), (52, 56, 64), (34, 32, 32)),
    ((236, 192, 154), (94, 54, 36), (112, 154, 176), (100, 84, 58), (46, 40, 34)),
    ((214, 162, 122), (32, 26, 22), (122, 90, 132), (58, 66, 70), (38, 36, 34)),
]

SHADOW = 0.78  # затемнение боковых/задних граней


def shade(color, factor):
    return tuple(max(0, min(255, int(c * factor))) for c in color[:3])


def fill(draw, box, color):
    x, y, w, h = box
    draw.rectangle([x, y, x + w - 1, y + h - 1], fill=color + (255,))


def draw_skin(path, palette, variant):
    skin, hair, shirt, pants, shoes = palette
    img = Image.new("RGBA", (64, 32), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # --- голова ---
    for side, factor in (("top", 1.0), ("bottom", SHADOW), ("right", 0.86),
                         ("front", 1.0), ("left", 0.86), ("back", 0.82)):
        fill(d, HEAD[side], shade(skin, factor))

    # волосы: макушка, верх лба, затылок и бока
    fill(d, HEAD["top"], hair)
    hx, hy, hw, _ = HEAD["front"]
    d.rectangle([hx, hy, hx + hw - 1, hy + 1], fill=hair + (255,))
    fill(d, HEAD["back"], shade(hair, 0.9))
    for side in ("left", "right"):
        x, y, w, h = HEAD[side]
        d.rectangle([x, y, x + w - 1, y + 2], fill=shade(hair, 0.88) + (255,))

    # лицо: глаза, рот, брови
    fx, fy, _, _ = HEAD["front"]
    eye = (38, 42, 56)
    d.rectangle([fx + 1, fy + 4, fx + 2, fy + 4], fill=eye + (255,))
    d.rectangle([fx + 5, fy + 4, fx + 6, fy + 4], fill=eye + (255,))
    d.rectangle([fx + 2, fy + 6, fx + 5, fy + 6], fill=(150, 86, 74, 255))
    if variant % 3 == 0:  # улыбка
        d.point([(fx + 1, fy + 6), (fx + 6, fy + 6)], fill=(150, 86, 74, 255))
    if variant % 4 == 1:  # борода
        d.rectangle([fx, fy + 6, fx + 7, fy + 7], fill=shade(hair, 0.95) + (255,))

    # --- туловище ---
    for side, factor in (("top", 1.0), ("bottom", SHADOW), ("right", 0.88),
                         ("front", 1.0), ("left", 0.88), ("back", 0.84)):
        fill(d, BODY[side], shade(shirt, factor))
    bx, by, bw, bh = BODY["front"]
    # воротник и пояс
    d.rectangle([bx + 2, by, bx + 5, by + 1], fill=shade(skin, 0.95) + (255,))
    d.rectangle([bx, by + bh - 2, bx + bw - 1, by + bh - 1], fill=shade(pants, 1.0) + (255,))

    # --- руки (правые; левые зеркалятся моделью) ---
    for side, factor in (("top", 1.0), ("bottom", SHADOW), ("right", 0.88),
                         ("front", 1.0), ("left", 0.88), ("back", 0.84)):
        fill(d, ARM[side], shade(shirt, factor))
    ax, ay, aw, ah = ARM["front"]
    d.rectangle([ax, ay + 4, ax + aw - 1, ay + ah - 1], fill=skin + (255,))  # кисть

    # --- нога ---
    for side, factor in (("top", 1.0), ("bottom", SHADOW), ("right", 0.88),
                         ("front", 1.0), ("left", 0.88), ("back", 0.84)):
        fill(d, LEG[side], shade(pants, factor))
    lx, ly, lw, lh = LEG["front"]
    d.rectangle([lx, ly + lh - 3, lx + lw - 1, ly + lh - 1], fill=shoes + (255,))

    img.save(path)


def draw_portrait(skin_path, portrait_path):
    """Портрет 32x32: лицо с классической раскладки скина, увеличенное в 4 раза."""
    skin = Image.open(skin_path).convert("RGBA")
    fx, fy, fw, fh = HEAD["front"]
    face = skin.crop((fx, fy, fx + fw, fy + fh))
    face = face.resize((32, 32), Image.NEAREST)
    face.save(portrait_path)


def draw_zzz(path):
    img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    white = (245, 250, 255, 255)
    d.line([(3, 4), (10, 4)], fill=white)
    d.line([(10, 4), (3, 11)], fill=white)
    d.line([(3, 11), (10, 11)], fill=white)
    d.line([(8, 1), (13, 1)], fill=white)
    d.line([(13, 1), (8, 6)], fill=white)
    img.save(path)


def draw_heart(path):
    img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.polygon([(8, 14), (1, 7), (1, 4), (4, 1), (8, 5), (12, 1), (15, 4), (15, 7)],
              fill=(236, 76, 96, 255))
    d.point([(4, 4), (5, 4), (11, 4), (12, 4)], fill=(255, 190, 200, 255))
    img.save(path)


def draw_anger(path):
    img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    red = (226, 64, 48, 255)
    d.line([(4, 2), (4, 7)], fill=red, width=3)
    d.line([(2, 5), (7, 5)], fill=red, width=3)
    d.line([(11, 7), (11, 12)], fill=red, width=3)
    d.line([(9, 10), (14, 10)], fill=red, width=3)
    img.save(path)


def draw_sweat(path):
    img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.polygon([(8, 1), (13, 9), (12, 13), (4, 13), (3, 9)], fill=(132, 198, 236, 255))
    d.point([(6, 9), (7, 9)], fill=(220, 244, 255, 255))
    img.save(path)


def draw_spawner(path):
    """Иконка предмета: голова NPC с искоркой."""
    img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    skin = (232, 190, 152, 255)
    hair = (74, 45, 30, 255)
    d.rectangle([2, 3, 13, 14], fill=skin)
    d.rectangle([2, 3, 13, 5], fill=hair)
    d.rectangle([4, 7, 5, 8], fill=(38, 42, 56, 255))
    d.rectangle([10, 7, 11, 8], fill=(38, 42, 56, 255))
    d.rectangle([5, 11, 10, 11], fill=(150, 86, 74, 255))
    d.point([(14, 1), (15, 2), (13, 2), (14, 3)], fill=(255, 230, 120, 255))
    img.save(path)


def draw_blank(path):
    Image.new("RGBA", (16, 16), (0, 0, 0, 0)).save(path)


def main():
    os.makedirs(TEX, exist_ok=True)
    for i, palette in enumerate(PALETTES, start=1):
        skin_path = os.path.join(TEX, "npc_skin_%d.png" % i)
        draw_skin(skin_path, palette, i)
        draw_portrait(skin_path, os.path.join(TEX, "npc_portrait_%d.png" % i))
    draw_zzz(os.path.join(TEX, "npc_zzz.png"))
    draw_heart(os.path.join(TEX, "npc_heart.png"))
    draw_anger(os.path.join(TEX, "npc_anger.png"))
    draw_sweat(os.path.join(TEX, "npc_sweat.png"))
    draw_spawner(os.path.join(TEX, "npc_spawner.png"))
    draw_blank(os.path.join(TEX, "npc_blank.png"))
    print("Готово: %d скинов, %d портретов и 6 служебных текстур в %s"
          % (len(PALETTES), len(PALETTES), os.path.normpath(TEX)))


if __name__ == "__main__":
    main()
