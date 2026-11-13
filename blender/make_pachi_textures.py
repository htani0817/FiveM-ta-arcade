# -*- coding: utf-8 -*-
# パチンコ台「宵花火」のテクスチャを作る（Pillow）
# py -3 make_pachi_textures.py  → blender/tex/ta_pachi_atlas.dds と確認用の .png、場所の表 pachi_layout.json
# 盤面の絵は、台の画面（html/pachi.js）と同じ寸法・同じ並べ方で描く（釘の位置も同じ決め方）
import json, math, os
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "tex")
os.makedirs(OUT, exist_ok=True)

FONT_B = "C:/Windows/Fonts/arialbd.ttf"
FONT_J = "C:/Windows/Fonts/YuGothB.ttc"

GOLD, GOLD_HI, GOLD_LO = (217, 166, 64, 255), (246, 217, 138, 255), (122, 90, 20, 255)
SHU, AI = (232, 69, 44, 255), (127, 184, 255, 255)
LACQUER = (7, 6, 11, 255)


def font(path, size):
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return ImageFont.load_default()


# ---------------------------------------------------------------------------
# アトラス 1024x1024。場所は pachi_layout.json に書き、build_pachi.py が UV に使う
# ---------------------------------------------------------------------------
A = Image.new("RGBA", (1024, 1024), (20, 16, 28, 255))
layout = {}


def put(name, im, x, y):
    A.alpha_composite(im, (x, y))
    layout[name] = [x, y, im.width, im.height]


# ---------------------------------------------------------------------------
# 盤面 512x560（台の窓 0.50m x 0.547m に貼る）。html/pachi.js の座標を 0.914 倍して描く
# ---------------------------------------------------------------------------
BW, BH = 512, 560
K = BW / 560.0                    # 画面の盤面（幅 560）からの倍率
CX, CY, R = 280, 292, 262         # 画面の盤面の円
LCD = (150, 136, 260, 160)
POCKET = {"heso": (280, 374), "denchu": (420, 398), "attacker": (388, 462), "out": (280, 540)}


def bx(x):
    return BW / 2 + (x - CX) * K


def by(y):
    return BH / 2 + (y - CY) * K


def nails():
    out = []

    def clear(x, y):
        if math.hypot(x - CX, y - CY) > R - 30:
            return False
        if LCD[0] - 16 < x < LCD[0] + LCD[2] + 16 and LCD[1] - 18 < y < LCD[1] + LCD[3] + 44:
            return False
        hx, hy = POCKET["heso"]
        if abs(x - hx) < 30 and hy - 40 < y < hy + 30:
            return False
        dx, dy = POCKET["denchu"]
        if abs(x - dx) < 34 and dy - 30 < y < dy + 24:
            return False
        ax, ay = POCKET["attacker"]
        if abs(x - ax) < 64 and ay - 30 < y < ay + 28:
            return False
        ox, oy = POCKET["out"]
        if abs(x - ox) < 40 and y > oy - 34:
            return False
        return True

    row, y = 0, 62
    while y < 540:
        x = 44 + (row % 2) * 18
        while x < 560 - 30:
            if clear(x, y):
                out.append((x, y))
            x += 36
        y += 31
        row += 1
    hy = POCKET["heso"][1]
    out += [(265, hy - 20), (295, hy - 20), (246, hy - 36), (314, hy - 36)]
    return out


board = Image.new("RGBA", (BW, BH), LACQUER)
d = ImageDraw.Draw(board)
# 四隅の金の筋
for i in range(1, 6):
    o = i * 9 * K
    for (x, y, sx, sy) in ((0, 0, 1, 1), (BW, 0, -1, 1), (0, BH, 1, -1), (BW, BH, -1, -1)):
        d.line((x + sx * o, y, x, y + sy * o), fill=(217, 166, 64, 80), width=1)
# 宵の空（外から中へ明るく）
rr = R * K
for i in range(60, 0, -1):
    t = i / 60.0
    c = (int(8 + (38 - 8) * (1 - t) ** 1.5), int(11 + (48 - 11) * (1 - t) ** 1.5), int(32 + (110 - 32) * (1 - t) ** 1.5), 255)
    r = rr * t
    cy = by(CY) - 55 * K * (1 - t)
    d.ellipse((bx(CX) - r, cy - r, bx(CX) + r, cy + r), fill=c)
# 遠くの花火
sky = Image.new("RGBA", (BW, BH), (0, 0, 0, 0))
ds = ImageDraw.Draw(sky)
for (x, y, r, col, n) in ((96, 226, 62, SHU, 18), (468, 200, 70, GOLD_HI, 20), (176, 470, 54, AI, 16), (280, 76, 46, GOLD_HI, 14), (476, 340, 38, SHU, 12)):
    for i in range(n):
        a = 2 * math.pi * i / n
        x0, y0 = bx(x) + math.cos(a) * r * K * 0.25, by(y) + math.sin(a) * r * K * 0.25
        x1, y1 = bx(x) + math.cos(a) * r * K, by(y) + math.sin(a) * r * K
        ds.line((x0, y0, x1, y1), fill=col[:3] + (95,), width=2)
        ds.ellipse((x1 - 2, y1 - 2, x1 + 2, y1 + 2), fill=col[:3] + (140,))
mask = Image.new("L", (BW, BH), 0)
ImageDraw.Draw(mask).ellipse((bx(CX) - rr, by(CY) - rr, bx(CX) + rr, by(CY) + rr), fill=255)
board.paste(Image.alpha_composite(board, sky), (0, 0), mask)
d = ImageDraw.Draw(board)
# 外枠のレール
d.ellipse((bx(CX) - rr, by(CY) - rr, bx(CX) + rr, by(CY) + rr), outline=GOLD, width=6)
r2 = (R - 20) * K
d.arc((bx(CX) - r2, by(CY) - r2, bx(CX) + r2, by(CY) + r2), 140, 292, fill=GOLD_LO, width=2)
# 釘
for (x, y) in nails():
    d.ellipse((bx(x) - 3, by(y) - 3, bx(x) + 3, by(y) + 3), fill=(201, 149, 46, 255))
    d.ellipse((bx(x) - 2, by(y) - 2, bx(x), by(y)), fill=(255, 243, 196, 255))
# アウト口
ox, oy = POCKET["out"]
d.ellipse((bx(ox) - 24, by(oy) - 8, bx(ox) + 24, by(oy) + 8), fill=(0, 0, 0, 255), outline=GOLD_LO, width=2)
# ヘソ
hx, hy = POCKET["heso"]
d.polygon([(bx(hx - 15), by(hy - 8)), (bx(hx + 15), by(hy - 8)), (bx(hx + 10), by(hy + 10)), (bx(hx - 10), by(hy + 10))], fill=SHU)
d.ellipse((bx(hx) - 10, by(hy - 6) - 4, bx(hx) + 10, by(hy - 6) + 4), fill=(18, 6, 10, 255))
# 電チュー（閉じた形）
dx, dy = POCKET["denchu"]
d.line((bx(dx - 9), by(dy + 6), bx(dx - 17), by(dy - 12)), fill=(74, 90, 138, 255), width=4)
d.line((bx(dx + 9), by(dy + 6), bx(dx + 17), by(dy - 12)), fill=(74, 90, 138, 255), width=4)
d.rectangle((bx(dx - 11), by(dy), bx(dx + 11), by(dy + 12)), fill=(42, 53, 102, 255))
# アタッカー（閉じた形）
ax, ay = POCKET["attacker"]
d.rectangle((bx(ax - 48), by(ay - 2), bx(ax + 48), by(ay + 12)), fill=(61, 44, 16, 255), outline=(109, 83, 32, 255), width=2)
# 液晶（奇数の 7 が揃った形で止めておく）
lx, ly, lw, lh = bx(LCD[0]), by(LCD[1]), LCD[2] * K, LCD[3] * K
for i in range(int(lh)):
    t = i / lh
    d.line((lx, ly + i, lx + lw, ly + i), fill=(int(6 + 23 * t), int(10 + 12 * t), int(30 + 30 * t), 255))
for k in range(26):
    sx, sy = lx + (k * 97 % 233) / 233.0 * lw, ly + (k * 53 % 101) / 101.0 * lh * 0.6
    d.point((sx, sy), fill=(255, 255, 255, 200))
d.rounded_rectangle((lx, ly, lx + lw, ly + lh), 9, outline=GOLD, width=4)
cw, ch = 62 * K, 96 * K
for i in range(3):
    cx0 = lx + lw / 2 + (i - 1) * 80 * K - cw / 2
    cy0 = ly + lh / 2 - ch / 2
    d.rounded_rectangle((cx0, cy0, cx0 + cw, cy0 + ch), 7, fill=(5, 6, 15, 200), outline=(246, 217, 138, 150), width=2)
    d.text((cx0 + cw / 2, cy0 + ch / 2), "7", font=font(FONT_B, int(72 * K)), fill=(255, 122, 99, 255), anchor="mm")
# 保留の玉（消えた形）
for i in range(4):
    hx0 = bx(CX) + (i - 1.5) * 26 * K
    hy0 = by(LCD[1] + LCD[3] + 20)
    d.ellipse((hx0 - 7, hy0 - 7, hx0 + 7, hy0 + 7), fill=(23, 28, 58, 255), outline=(65, 74, 133, 255))
put("board", board, 0, 0)

# ---------------------------------------------------------------------------
# データカウンターの画面 256x128
# ---------------------------------------------------------------------------
dc = Image.new("RGBA", (256, 128), (4, 3, 6, 255))
d = ImageDraw.Draw(dc)
for i, (lbl, val) in enumerate((("現在", "64"), ("確変", "7"), ("通常", "5"), ("総回転", "2210"))):
    x = 32 + i * 64
    d.text((x, 34), lbl, font=font(FONT_J, 15), fill=(169, 159, 140, 255), anchor="mm")
    d.text((x, 78), val, font=font(FONT_B, 26 if len(val) < 4 else 20), fill=(255, 59, 47, 255), anchor="mm")
d.rectangle((0, 0, 255, 127), outline=(80, 64, 30, 255), width=3)
put("counter", dc, 512, 0)

# ハンドルの頭 128x128（銀の輪と朱の芯）
hd = Image.new("RGBA", (128, 128), (36, 30, 24, 255))
d = ImageDraw.Draw(hd)
for r in range(64, 0, -1):
    t = r / 64.0
    v = int(90 + 130 * (1 - abs(t - 0.75) * 4)) if t > 0.5 else 0
    c = (v, v, v, 255) if t > 0.5 else (int(140 + 92 * (1 - t * 2)), int(31 + 38 * (1 - t * 2)), int(6 + 38 * (1 - t * 2)), 255)
    d.ellipse((64 - r, 64 - r, 64 + r, 64 + r), fill=c)
put("handle", hd, 768, 0)

# 皿の玉 128x128（銀の玉を並べる）
bl = Image.new("RGBA", (128, 128), (24, 20, 14, 255))
d = ImageDraw.Draw(bl)
for row in range(8):
    for col in range(9):
        x, y = col * 16 - (8 if row % 2 else 0), row * 16
        d.ellipse((x, y, x + 15, y + 15), fill=(109, 113, 128, 255))
        d.ellipse((x + 1, y + 1, x + 12, y + 12), fill=(207, 210, 218, 255))
        d.ellipse((x + 3, y + 3, x + 7, y + 7), fill=(255, 255, 255, 255))
put("balls", bl, 896, 0)

# 名前の板 512x96
pl = Image.new("RGBA", (512, 96), (13, 20, 48, 255))
d = ImageDraw.Draw(pl)
for y in range(96):
    t = y / 95.0
    d.line((0, y, 511, y), fill=(int(13 + 14 * t), int(20 + 16 * t), int(48 + 34 * t), 255))
for (x, col) in ((70, SHU), (442, GOLD_HI)):
    for i in range(14):
        a = 2 * math.pi * i / 14
        d.line((x + math.cos(a) * 9, 48 + math.sin(a) * 9, x + math.cos(a) * 34, 48 + math.sin(a) * 34), fill=col[:3] + (255,), width=2)
d.text((256, 46), "宵花火", font=font(FONT_J, 54), fill=GOLD_HI, anchor="mm")
d.rectangle((0, 0, 511, 95), outline=GOLD, width=3)
put("plate", pl, 512, 128)

# 側面（黒漆に金の細線）256x512
side = Image.new("RGBA", (256, 512), (0, 0, 0, 255))
d = ImageDraw.Draw(side)
for y in range(512):
    t = y / 511
    d.line((0, y, 255, y), fill=(int(22 + 10 * t), int(18 + 4 * t), int(34 + 12 * t), 255))
d.rectangle((10, 10, 245, 501), outline=GOLD, width=3)
d.rectangle((18, 18, 237, 493), outline=(120, 90, 30, 255), width=1)
put("side", side, 512, 224)

# 台座の正面（黒に金の枠）256x256
base = Image.new("RGBA", (256, 256), (14, 12, 18, 255))
d = ImageDraw.Draw(base)
d.rectangle((12, 12, 243, 243), outline=GOLD, width=3)
d.text((128, 128), "宵花火", font=font(FONT_J, 40), fill=(120, 90, 30, 255), anchor="mm")
put("stand", base, 768, 224)

# 銀（皿・ハンドル）128x64
chrome = Image.new("RGBA", (128, 64), (0, 0, 0, 255))
d = ImageDraw.Draw(chrome)
for y in range(64):
    v = int(120 + 120 * (1 - abs(y - 20) / 44))
    d.line((0, y, 127, y), fill=(v, v, v, 255))
put("chrome", chrome, 768, 480)

# 上のランプ 256x32（7 つに分かれた朱と金）
lb = Image.new("RGBA", (256, 32), (12, 10, 16, 255))
d = ImageDraw.Draw(lb)
for i in range(7):
    x0 = 6 + i * 35
    d.rounded_rectangle((x0, 6, x0 + 30, 26), 6, fill=SHU if i % 2 == 0 else GOLD_HI)
put("lampbar", lb, 768, 544)

# 色の見本（単色の面に使う）64x64 を下に並べる
swatches = {
    "black": (12, 10, 16, 255), "lacquer": (26, 21, 38, 255), "gold": GOLD,
    "goldhi": GOLD_HI, "shu": SHU, "grey": (70, 66, 62, 255),
    "silver": (190, 190, 195, 255), "dark": (36, 30, 24, 255), "ai": AI,
    "glass": (10, 14, 34, 255),
}
for i, (k, c) in enumerate(swatches.items()):
    x, y = (i % 16) * 64, 960 - (i // 16) * 64
    A.alpha_composite(Image.new("RGBA", (64, 64), c), (x, y))
    layout["sw_" + k] = [x + 16, y + 16, 32, 32]  # 縁を避けて真ん中だけ使う

A.convert("RGB").save(os.path.join(OUT, "ta_pachi_atlas.png"))
A.convert("RGB").save(os.path.join(OUT, "ta_pachi_atlas.dds"), pixel_format="DXT1")
json.dump(layout, open(os.path.join(OUT, "pachi_layout.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("ok", len(layout))
