# -*- coding: utf-8 -*-
# 盤面と玉の軌道を絵にする（釘を直すときに、玉がどう流れるかを目で見る用）
#   node lua-run.js pachi-export.lua paths 40 55 > paths.json
#   py -3 pachi-draw.py paths.json out.png
# 軌道の色: ヘソ=黄、電チュー=水色、アタッカー=金、一般入賞口=緑、アウト=灰
import json
import sys
from PIL import Image, ImageDraw

data = json.load(open(sys.argv[1], encoding="utf-8"))
b = data["board"]
S = 3  # 拡大
im = Image.new("RGB", (b["W"] * S, b["H"] * S), (8, 8, 20))
d = ImageDraw.Draw(im, "RGBA")


def circ(x, y, r, **kw):
    d.ellipse((x * S - r * S, y * S - r * S, x * S + r * S, y * S + r * S), **kw)


circ(b["cx"], b["cy"], b["wall"], outline=(217, 166, 64), width=3)
l = b["lcd"]
d.rectangle((l["x"] * S, l["y"] * S, (l["x"] + l["w"]) * S, (l["y"] + l["h"]) * S), outline=(217, 166, 64), fill=(20, 26, 60))
COL = {"heso": (255, 230, 60, 150), "denchu": (120, 200, 255, 150), "attacker": (246, 217, 138, 150), "general": (120, 255, 140, 150), "miss": (150, 150, 160, 60)}
for sh in data.get("shots", []):
    p = sh["path"]
    pts = [(p[i] / 2 * S, p[i + 1] / 2 * S) for i in range(0, len(p), 2)]
    if len(pts) > 1:
        d.line(pts, fill=COL[sh["to"]], width=2 if sh["to"] == "miss" else 3)
for n in b["nails"]:
    circ(n["x"], n["y"], b["nailR"], fill=(230, 180, 70))
for w in b["windmills"]:
    circ(w["x"], w["y"], w["r"], fill=(200, 80, 60))
circ(b["rubber"]["x"], b["rubber"]["y"], b["rubber"]["r"], fill=(90, 90, 90))
pk = b["pocket"]
circ(pk["heso"]["x"], pk["heso"]["y"], pk["heso"]["r"], fill=(232, 69, 44))
for g in pk["general"]:
    circ(g["x"], g["y"], g["r"], fill=(60, 200, 90))
for k, col in (("denchu", (127, 184, 255)), ("attacker", (246, 217, 138))):
    q = pk[k]
    d.rectangle(((q["x"] - q["w"]) * S, (q["y"] - q["h"]) * S, (q["x"] + q["w"]) * S, (q["y"] + q["h"]) * S), fill=col)
o = pk["out"]
d.rectangle(((o["x"] - o["w"]) * S, (o["y"] - 12) * S, (o["x"] + o["w"]) * S, (o["y"] + 4) * S), outline=(255, 255, 255))
im.save(sys.argv[2])
print("saved", sys.argv[2], len(data.get("shots", [])))
