# -*- coding: utf-8 -*-
# 台と椅子のテクスチャを作る（Pillow）。design/png の絵と engine.lua のリール配列を使う
# py -3 make_textures.py  → blender/tex/*.dds と確認用の *.png、場所の表 layout.json
import json, os, re
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PNG = os.path.join(ROOT, "design", "png")
OUT = os.path.join(HERE, "tex")
os.makedirs(OUT, exist_ok=True)

FONT_B = "C:/Windows/Fonts/arialbd.ttf"
FONT_J = "C:/Windows/Fonts/YuGothB.ttc"


def font(path, size):
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return ImageFont.load_default()


def load(name, size=None):
    im = Image.open(os.path.join(PNG, name + ".png")).convert("RGBA")
    return im.resize(size, Image.LANCZOS) if size else im


# ---------------------------------------------------------------------------
# アトラス 1024x1024。場所は layout.json に書き、build_models.py が UV に使う
# ---------------------------------------------------------------------------
A = Image.new("RGBA", (1024, 1024), (20, 16, 28, 255))
layout = {}


def put(name, im, x, y):
    A.alpha_composite(im, (x, y))
    layout[name] = [x, y, im.width, im.height]


def flat(color, w=60, h=60):
    return Image.new("RGBA", (w, h), color)


# 上部パネルと下部パネル
put("upper", load("panel_upper", (512, 320)), 0, 0)
put("lower", load("panel_lower", (512, 256)), 512, 0)

# 表示の段（告知ランプの横のクレジットと PAY の表示）512x96
info = Image.new("RGBA", (512, 96), (8, 7, 12, 255))
d = ImageDraw.Draw(info)
for i, (lbl, val) in enumerate((("CREDIT", "50"), ("PAY", "0"))):
    x0 = 150 + i * 180
    d.rounded_rectangle((x0, 10, x0 + 160, 86), 8, fill=(4, 3, 6, 255), outline=(40, 32, 18, 255), width=2)
    d.text((x0 + 80, 22), lbl, font=font(FONT_B, 14), fill=(169, 159, 140, 255), anchor="mm")
    d.text((x0 + 80, 58), val, font=font(FONT_B, 40), fill=(255, 59, 47, 255), anchor="mm")
for k in range(3):
    d.rounded_rectangle((100, 14 + k * 24, 136, 32 + k * 24), 3, fill=(217, 166, 64, 255))
put("info", info, 512, 256)
# 告知ランプ（消灯の絵。光は emissive で出る）
put("lamp", load("lamp_on", (96, 120)), 512 + 4, 360)

# データカウンターの画面 256x128
dc = Image.new("RGBA", (256, 128), (4, 3, 6, 255))
d = ImageDraw.Draw(dc)
for i, (lbl, val) in enumerate((("現在", "87"), ("BIG", "4"), ("REG", "3"), ("総回転", "1234"))):
    x = 32 + i * 64
    d.text((x, 34), lbl, font=font(FONT_J, 15), fill=(169, 159, 140, 255), anchor="mm")
    d.text((x, 78), val, font=font(FONT_B, 26 if len(val) < 4 else 20), fill=(255, 59, 47, 255), anchor="mm")
d.rectangle((0, 0, 255, 127), outline=(80, 64, 30, 255), width=3)
put("counter", dc, 0, 320)

# 側面（黒漆に金の細線）256x512
side = Image.new("RGBA", (256, 512), (0, 0, 0, 255))
d = ImageDraw.Draw(side)
for y in range(512):
    t = y / 511
    c = (int(22 + 10 * t), int(18 + 4 * t), int(34 + 12 * t), 255)
    d.line((0, y, 255, y), fill=c)
d.rectangle((10, 10, 245, 501), outline=(217, 166, 64, 255), width=3)
d.rectangle((18, 18, 237, 493), outline=(120, 90, 30, 255), width=1)
put("side", side, 768, 464)

# 台座の正面（黒に金の枠）256x256
base = Image.new("RGBA", (256, 256), (14, 12, 18, 255))
d = ImageDraw.Draw(base)
d.rectangle((12, 12, 243, 243), outline=(217, 166, 64, 255), width=3)
d.text((128, 128), "夜祭", font=font(FONT_J, 44), fill=(120, 90, 30, 255), anchor="mm")
put("stand", base, 256, 320)

# ボタンの頭（停止ボタン、MAX BET）
btn = Image.new("RGBA", (96, 96), (0, 0, 0, 255))
d = ImageDraw.Draw(btn)
for r in range(48, 0, -1):
    t = r / 48
    d.ellipse((48 - r, 48 - r, 48 + r, 48 + r), fill=(int(140 + 115 * (1 - t)), int(31 + 160 * (1 - t) ** 2), int(6 + 100 * (1 - t) ** 3), 255))
put("stopbtn", btn, 640, 360)
mb = Image.new("RGBA", (96, 96), (201, 149, 46, 255))
d = ImageDraw.Draw(mb)
d.rectangle((0, 0, 95, 47), fill=(247, 220, 138, 255))
d.text((48, 34), "MAX", font=font(FONT_B, 22), fill=(59, 42, 7, 255), anchor="mm")
d.text((48, 64), "BET", font=font(FONT_B, 22), fill=(59, 42, 7, 255), anchor="mm")
put("maxbet", mb, 736, 360)

# 椅子の座面（赤い革）128x128
lea = Image.new("RGBA", (128, 128), (150, 20, 24, 255))
d = ImageDraw.Draw(lea)
for i in range(0, 128, 16):
    d.line((i, 0, i, 127), fill=(120, 14, 18, 255), width=2)
lea = lea.filter(ImageFilter.GaussianBlur(1.2))
put("leather", lea, 256, 576)

# 銀（受け皿・レバー）
chrome = Image.new("RGBA", (128, 64), (0, 0, 0, 255))
d = ImageDraw.Draw(chrome)
for y in range(64):
    v = int(120 + 120 * (1 - abs(y - 20) / 44))
    d.line((0, y, 127, y), fill=(v, v, v, 255))
put("chrome", chrome, 384, 576)

# 色の見本（単色の面に使う）64x64 を下に並べる
swatches = {
    "black": (12, 10, 16, 255), "lacquer": (26, 21, 38, 255), "gold": (217, 166, 64, 255),
    "goldhi": (246, 217, 138, 255), "shu": (232, 69, 44, 255), "grey": (70, 66, 62, 255),
    "silver": (190, 190, 195, 255), "dark": (36, 30, 24, 255), "reelbg": (244, 236, 214, 255),
    "red": (200, 30, 28, 255), "screen": (4, 3, 6, 255), "brown": (60, 45, 30, 255),
}
for i, (k, c) in enumerate(swatches.items()):
    x, y = (i % 16) * 64, 960 - (i // 16) * 64
    A.alpha_composite(flat(c, 64, 64), (x, y))
    layout["sw_" + k] = [x + 16, y + 16, 32, 32]  # 縁を避けて真ん中だけ使う

A.convert("RGB").save(os.path.join(OUT, "ta_slot_atlas.png"))
A.convert("RGB").save(os.path.join(OUT, "ta_slot_atlas.dds"), pixel_format="DXT1")

# ---------------------------------------------------------------------------
# リール帯 1024x2048。左・中・右を 256 幅で並べる（残りの 256 は使わない）
# 下から上へ 0,1,2… の順（3D のリールは正面を上へ行くほど番号が増える）
# ---------------------------------------------------------------------------
src = open(os.path.join(ROOT, "shared", "slot_engine.lua"), encoding="utf-8").read()
strips = [m.replace("'", "").split(", ") for m in re.findall(r"\{ ('[A-Z0-9]{2}'(?:, '[A-Z0-9]{2}'){20}) \}", src)]
assert len(strips) == 3, "engine.lua のリール配列が読めません"
names = {"R7": "seven", "LN": "lantern", "BR": "bar", "BL": "bell", "SK": "suika", "CH": "cherry", "RP": "replay"}
R = Image.new("RGBA", (1024, 2048), (244, 236, 214, 255))
cell = 2048 / 21
for ri, strip in enumerate(strips):
    for i, s in enumerate(strip):
        im = load("sym_" + names[s])
        # 3D のリール（半径 0.11m・幅 0.075m）で 4:3 に見える大きさ。横 3413px/m、縦 2955px/m
        w, h = 137, 89
        im = im.resize((w, h), Image.LANCZOS)
        top = 2048 - (i + 1) * cell
        R.alpha_composite(im, (ri * 256 + (256 - w) // 2, int(top + (cell - h) / 2)))
R.convert("RGB").save(os.path.join(OUT, "ta_slot_reel.png"))
R.convert("RGB").save(os.path.join(OUT, "ta_slot_reel.dds"), pixel_format="DXT1")
layout["_strips"] = strips

json.dump(layout, open(os.path.join(OUT, "layout.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("ok", len(layout))
