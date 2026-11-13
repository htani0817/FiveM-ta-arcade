# -*- coding: utf-8 -*-
# パチンコ台「宵花火」を Blender で組み立て、Sollumz で FiveM 用に書き出す
# 先に py -3 make_pachi_textures.py でテクスチャを作ってから:
#   blender --background --python build_pachi.py
# 出力: ../stream/ta_pachi_machine.ydr, ta_pachi.ytyp
#       ./ta_pachi.blend（Blender で開いて直せる）、./preview/pachi_*.png（確認用の描画）
# 台の正面は -Y（座る人は +Y を向く）。原点は床の中心。椅子はパチスロの ta_slot_chair を使う
# 台座と本体の大きさはパチスロと同じにしてある（並べたときに揃う。Config.Games の width も同じ）
import bpy, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TEX = os.path.join(HERE, "tex")
PREVIEW = os.path.join(HERE, "preview")
os.makedirs(PREVIEW, exist_ok=True)
# パチンコの分だけを別のフォルダに書き出してから stream/ へ写す（stream/ のパチスロのファイルには触らない）
OUT = os.path.join(HERE, "_pachi_out")
os.makedirs(OUT, exist_ok=True)

sys.path.insert(0, HERE)
import common
from common import MAT_BODY, MAT_GLOW, add_bounds

LAYOUT = json.load(open(os.path.join(TEX, "pachi_layout.json"), encoding="utf-8"))

common.reset_scene()


def build_machine():
    B = common.Builder(LAYOUT)
    gold = ("sw_gold", MAT_BODY)
    black = ("sw_black", MAT_BODY)
    silver = ("sw_silver", MAT_BODY)
    dark = ("sw_dark", MAT_BODY)
    chrome = ("chrome", MAT_BODY)

    # 台座（島）
    B.box((-0.30, -0.25, 0.0), (0.30, 0.25, 0.78), {"front": ("stand", MAT_BODY), "top": dark}, black)
    # 本体（正面は部品でふさぐので作らない）
    B.box((-0.27, -0.20, 0.78), (0.27, 0.22, 1.64),
          {"left": ("side", MAT_BODY), "right": ("side", MAT_BODY), "top": black}, black, skip=("front", "bottom"))
    # 正面の金の縁（左右と上）
    B.box((-0.285, -0.215, 0.78), (-0.265, -0.19, 1.66), {}, gold)
    B.box((0.265, -0.215, 0.78), (0.285, -0.19, 1.66), {}, gold)
    B.box((-0.285, -0.215, 1.64), (0.285, -0.19, 1.66), {}, gold)
    B.box((-0.27, -0.19, 1.64), (0.27, 0.22, 1.65), {}, black)

    # 下の段: 後ろの板、下皿（左）、ハンドル（右）
    B.box((-0.265, -0.205, 0.78), (0.265, -0.20, 0.90), {}, black)
    B.box((-0.23, -0.33, 0.795), (0.07, -0.205, 0.85), {"top": ("sw_grey", MAT_BODY)}, chrome)
    B.box((-0.21, -0.31, 0.85), (0.05, -0.215, 0.853), {"top": ("balls", MAT_BODY)}, dark)
    # ハンドル（前へ突き出す円盤と、握りの出っ張り）
    B.cylinder((0.185, -0.225, 0.845), "Y", 0.022, 0.05, 16, silver, silver)
    B.cylinder((0.185, -0.265, 0.845), "Y", 0.05, 0.035, 28, chrome, dark, cap2=("handle", MAT_BODY))  # cap2 が正面（-Y）
    B.box((0.178, -0.29, 0.875), (0.192, -0.25, 0.905), {}, silver)

    # 名前の板（枠と絵）
    B.box((-0.265, -0.210, 0.90), (0.265, -0.20, 0.985), {}, gold)
    B.box((-0.25, -0.214, 0.908), (0.25, -0.210, 0.977), {"front": ("plate", MAT_GLOW)}, black)

    # 上皿（玉が入っている）
    B.box((-0.265, -0.205, 0.985), (0.265, -0.20, 1.06), {}, black)
    B.box((-0.24, -0.33, 1.0), (0.24, -0.205, 1.045), {"top": ("sw_grey", MAT_BODY)}, chrome)
    B.box((-0.22, -0.315, 1.045), (0.22, -0.215, 1.048), {"top": ("balls", MAT_BODY)}, dark)
    # 上皿の右の玉貸しボタン
    B.cylinder((0.20, -0.30, 1.05), "Z", 0.014, 0.01, 14, dark, ("sw_shu", MAT_GLOW), cap2=dark)

    # 盤面（金の枠とガラスの中の絵）。窓は 0.50m x 0.547m
    B.box((-0.265, -0.212, 1.06), (0.265, -0.20, 1.64), {}, gold)
    B.box((-0.25, -0.216, 1.068), (0.25, -0.212, 1.615), {"front": ("board", MAT_GLOW)}, black)
    # 上のランプ
    B.box((-0.25, -0.218, 1.618), (0.25, -0.212, 1.636), {"front": ("lampbar", MAT_GLOW)}, black)

    # データカウンター（柱と箱）
    B.cylinder((0.0, 0.0, 1.69), "Z", 0.014, 0.06, 12, silver, silver)
    B.box((-0.15, -0.06, 1.72), (0.15, 0.06, 1.88), {}, black)
    B.box((-0.13, -0.064, 1.735), (0.13, -0.06, 1.865), {"front": ("counter", MAT_GLOW)}, black)
    B.box((-0.15, -0.065, 1.88), (0.15, 0.065, 1.89), {"top": ("sw_ai", MAT_GLOW)}, ("sw_ai", MAT_GLOW))

    mats = [
        common.material(TEX, "default.sps", "ta_pachi_atlas", name="ta_pachi_body"),
        common.material(TEX, "emissive.sps", "ta_pachi_atlas", 1.6, name="ta_pachi_glow"),
    ]
    d = B.to_drawable("ta_pachi_machine", mats)
    add_bounds(d, [((-0.30, -0.33, 0.0), (0.30, 0.25, 1.66)), ((-0.15, -0.065, 1.66), (0.15, 0.065, 1.89))], "METAL_SOLID_MEDIUM")
    return d


machine = build_machine()

# ---------------------------------------------------------------------------
# ytyp・書き出し
# ---------------------------------------------------------------------------
common.make_ytyp("ta_pachi", (machine,))
common.export(OUT)
import shutil
for name in ("ta_pachi_machine.ydr", "ta_pachi.ytyp"):
    shutil.copyfile(os.path.join(OUT, name), os.path.join(ROOT, "stream", name))
    print("stream/" + name, os.path.getsize(os.path.join(ROOT, "stream", name)))
shutil.rmtree(OUT)
common.save_blend(os.path.join(HERE, "ta_pachi.blend"))

# ---------------------------------------------------------------------------
# 確認用の描画
# ---------------------------------------------------------------------------
shot = common.setup_render(PREVIEW)
shot("pachi_front", (0.0, -2.6, 1.25), (0.0, 0.0, 1.0), 32)
shot("pachi_three_quarter", (1.7, -2.2, 1.7), (0.0, -0.3, 0.9), 30)
shot("pachi_shelf", (0.5, -1.0, 1.25), (0.0, -0.25, 0.95), 40)
print("done")
