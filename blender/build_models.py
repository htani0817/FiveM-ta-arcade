# -*- coding: utf-8 -*-
# パチスロ台「夜祭」と椅子を Blender で組み立て、Sollumz で FiveM 用に書き出す
# 先に py -3 make_textures.py でテクスチャを作ってから:
#   blender --background --python build_models.py
# 出力: ../stream/ta_slot_machine.ydr, ta_slot_chair.ydr, ta_slot.ytyp
#       ./ta_slot.blend（Blender で開いて直せる）、./preview/*.png（確認用の描画）
# 台の正面は -Y（座る人は +Y を向く）。原点は床の中心
import bpy, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TEX = os.path.join(HERE, "tex")
STREAM = os.path.join(ROOT, "stream")
PREVIEW = os.path.join(HERE, "preview")
os.makedirs(STREAM, exist_ok=True)
os.makedirs(PREVIEW, exist_ok=True)

# 形を作る道具・材質・コリジョン・書き出しは common.py（パチンコの build_pachi.py と共通）
sys.path.insert(0, HERE)
import common
from common import MAT_BODY, MAT_GLOW, add_bounds, convert_obj_to_drawable

LAYOUT = json.load(open(os.path.join(TEX, "layout.json"), encoding="utf-8"))
STRIPS = LAYOUT["_strips"]
N = 21
MAT_REEL = 2  # 材質（0 = 本体、1 = 光る面、2 = リール）

common.reset_scene()


def Builder():
    return common.Builder(LAYOUT)


def material(shader, tex, emissive=None, name=None):
    return common.material(TEX, shader, tex, emissive, name)


# ---------------------------------------------------------------------------
# 台
# ---------------------------------------------------------------------------
def build_machine():
    B = Builder()
    gold = ("sw_gold", MAT_BODY)
    black = ("sw_black", MAT_BODY)
    lac = ("sw_lacquer", MAT_BODY)
    silver = ("sw_silver", MAT_BODY)
    dark = ("sw_dark", MAT_BODY)

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

    # 受け皿の後ろの板と受け皿
    B.box((-0.265, -0.205, 0.78), (0.265, -0.20, 0.86), {}, black)
    B.box((-0.24, -0.33, 0.79), (0.24, -0.205, 0.845), {"top": ("sw_grey", MAT_BODY)}, ("chrome", MAT_BODY))
    B.box((-0.22, -0.31, 0.845), (0.22, -0.215, 0.85), {}, dark)
    # 下部パネル（枠と絵）
    B.box((-0.265, -0.210, 0.85), (0.265, -0.20, 1.05), {}, gold)
    B.box((-0.25, -0.214, 0.865), (0.25, -0.210, 1.035), {"front": ("lower", MAT_GLOW)}, black)
    # 操作部（棚）
    B.box((-0.265, -0.31, 1.05), (0.265, -0.20, 1.10), {"top": dark, "front": gold}, black)
    for x in (-0.075, 0.0, 0.075):  # 停止ボタン
        B.cylinder((x, -0.265, 1.1075), "Z", 0.022, 0.015, 20, dark, ("stopbtn", MAT_GLOW), cap2=dark)
    B.box((0.135, -0.29, 1.10), (0.195, -0.245, 1.112), {"top": ("maxbet", MAT_GLOW)}, ("sw_brown", MAT_BODY))  # MAX BET
    B.box((0.205, -0.275, 1.10), (0.25, -0.235, 1.106), {}, silver)   # メダル投入口
    B.box((0.215, -0.258, 1.106), (0.24, -0.252, 1.108), {}, black)
    # レバー（前へ突き出す棒と赤い玉）
    B.cylinder((-0.20, -0.29, 1.08), "Z", 0.012, 0.012, 12, silver, silver)
    B.cylinder((-0.20, -0.33, 1.088), "Y", 0.006, 0.08, 10, silver, silver)
    B.sphere((-0.20, -0.375, 1.088), 0.018, 16, 10, "sw_red", MAT_BODY)

    # 表示の段（クレジット・PAY）と告知ランプ
    B.box((-0.265, -0.210, 1.10), (0.265, -0.20, 1.17), {}, black)
    B.box((-0.25, -0.214, 1.103), (0.25, -0.210, 1.167), {"front": ("info", MAT_GLOW)}, black)
    B.box((-0.245, -0.222, 1.105), (-0.195, -0.214, 1.165), {"front": ("lamp", MAT_GLOW)}, black)

    # リール窓の枠（真ん中は穴）
    wx, wz0, wz1 = 0.135, 1.205, 1.325
    fr = {"front": ("sw_lacquer", MAT_BODY)}
    B.box((-0.265, -0.215, 1.17), (-wx, -0.20, 1.36), fr, gold)
    B.box((wx, -0.215, 1.17), (0.265, -0.20, 1.36), fr, gold)
    B.box((-wx, -0.215, 1.17), (wx, -0.20, wz0), fr, gold)
    B.box((-wx, -0.215, wz1), (wx, -0.20, 1.36), fr, gold)
    # 金の細い縁取り（窓のまわり）
    B.box((-wx - 0.006, -0.217, wz0 - 0.006), (wx + 0.006, -0.215, wz0), {}, gold)
    B.box((-wx - 0.006, -0.217, wz1), (wx + 0.006, -0.215, wz1 + 0.006), {}, gold)
    B.box((-wx - 0.006, -0.217, wz0), (-wx, -0.215, wz1), {}, gold)
    B.box((wx, -0.217, wz0), (wx + 0.006, -0.215, wz1), {}, gold)
    # 窓の奥（内側を向いた箱）
    B.box((-wx, -0.20, wz0), (wx, 0.02, wz1), {}, black, skip=("front",), inward=True)

    # リール 3 本。中段に 7 が並んだ形で止めておく
    reel_r, reel_w = 0.11, 0.075
    zc = (wz0 + wz1) / 2
    for i, x in enumerate((-0.085, 0.0, 0.085)):
        strip = STRIPS[i]
        p = next(k for k in range(N) if strip[(k + 1) % N] == "R7")
        u0, u1 = i * 0.25, i * 0.25 + 0.25
        voff = (p + 1.5) / N  # 正面の真ん中に p+1 番の図柄の中心

        def suv(t, a, u0=u0, u1=u1, voff=voff):
            return (u0 + (u1 - u0) * t, voff + a)

        B.cylinder((x, -0.20 + 0.003 + reel_r, zc), "X", reel_r, reel_w, 42, ((0, 0, 1, 1), MAT_REEL),
                   ("sw_reelbg", MAT_BODY), side_uv=suv)

    # 上部パネル（枠と絵）
    B.box((-0.265, -0.212, 1.36), (0.265, -0.20, 1.64), {}, gold)
    B.box((-0.25, -0.216, 1.375), (0.25, -0.212, 1.625), {"front": ("upper", MAT_GLOW)}, black)

    # データカウンター（柱と箱）
    B.cylinder((0.0, 0.0, 1.69), "Z", 0.014, 0.06, 12, silver, silver)
    B.box((-0.15, -0.06, 1.72), (0.15, 0.06, 1.88), {}, black)
    B.box((-0.13, -0.064, 1.735), (0.13, -0.06, 1.865), {"front": ("counter", MAT_GLOW)}, black)
    B.box((-0.15, -0.065, 1.88), (0.15, 0.065, 1.89), {"top": ("sw_shu", MAT_GLOW)}, ("sw_shu", MAT_GLOW))

    mats = [
        material("default.sps", "ta_slot_atlas", name="ta_slot_body"),
        material("emissive.sps", "ta_slot_atlas", 1.6, name="ta_slot_glow"),
        material("emissive.sps", "ta_slot_reel", 0.45, name="ta_slot_reel"),
    ]
    obj = B.to_object("ta_slot_machine", mats)
    d = convert_obj_to_drawable(obj)
    d.name = "ta_slot_machine"
    add_bounds(d, [((-0.30, -0.33, 0.0), (0.30, 0.25, 1.66)), ((-0.15, -0.065, 1.66), (0.15, 0.065, 1.89))], "METAL_SOLID_MEDIUM")
    return d


# ---------------------------------------------------------------------------
# 椅子（座る人は +Y を向く。背もたれは -Y 側）
# ---------------------------------------------------------------------------
def build_chair():
    B = Builder()
    black = ("sw_black", MAT_BODY)
    silver = ("sw_silver", MAT_BODY)
    lea = ("leather", MAT_BODY)
    B.cylinder((0, 0, 0.015), "Z", 0.22, 0.03, 32, black, ("sw_dark", MAT_BODY), cap2=black)
    B.cylinder((0, 0, 0.29), "Z", 0.035, 0.52, 16, silver, silver)
    # 足を掛ける横棒
    B.box((-0.16, 0.10, 0.24), (0.16, 0.13, 0.26), {}, silver)
    B.box((-0.015, 0.0, 0.24), (0.015, 0.10, 0.26), {}, silver)
    # 座面
    B.cylinder((0, 0, 0.555), "Z", 0.205, 0.03, 32, black, black)
    B.cylinder((0, 0, 0.6), "Z", 0.20, 0.06, 32, lea, lea)
    # 背もたれ
    B.box((-0.02, -0.20, 0.57), (0.02, -0.17, 0.70), {}, silver)
    # 革の面は +Y（座った人の背中側）。-Y 側は黒い裏板
    B.box((-0.17, -0.205, 0.68), (0.17, -0.155, 0.95), {"back": lea, "top": lea, "left": lea, "right": lea}, black)
    B.box((-0.175, -0.225, 0.675), (0.175, -0.205, 0.955), {}, black)

    mats = [material("default.sps", "ta_slot_atlas", name="ta_slot_chair_body")]
    obj = B.to_object("ta_slot_chair", mats)
    d = convert_obj_to_drawable(obj)
    d.name = "ta_slot_chair"
    add_bounds(d, [((-0.05, -0.05, 0.0), (0.05, 0.05, 0.55)), ((-0.17, -0.225, 0.62), (0.17, -0.16, 0.955))], "PLASTIC")
    return d


machine = build_machine()
chair = build_chair()
chair.location = (0.0, -0.80, 0.0)  # 見た目の確認用（書き出しは原点基準）

# ---------------------------------------------------------------------------
# ytyp・書き出し（椅子の位置は原点に戻す）
# ---------------------------------------------------------------------------
common.make_ytyp("ta_slot", (machine, chair))
chair.location = (0.0, 0.0, 0.0)
common.export(STREAM)
chair.location = (0.0, -0.80, 0.0)
common.save_blend(os.path.join(HERE, "ta_slot.blend"))

# ---------------------------------------------------------------------------
# 確認用の描画
# ---------------------------------------------------------------------------
shot = common.setup_render(PREVIEW)
shot("front", (0.0, -2.6, 1.25), (0.0, 0.0, 1.0), 32)
shot("three_quarter", (1.7, -2.2, 1.7), (0.0, -0.3, 0.9), 30)
shot("reels", (0.0, -0.75, 1.27), (0.0, -0.2, 1.25), 40)
shot("chair", (1.0, -1.9, 0.9), (0.0, -0.8, 0.5), 35)
print("done")
