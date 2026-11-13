# -*- coding: utf-8 -*-
# パチスロ台「夜祭」と椅子を Blender で組み立て、Sollumz で FiveM 用に書き出す
# 先に py -3 make_textures.py でテクスチャを作ってから:
#   blender --background --python build_models.py
# 出力: ../stream/ta_slot_machine.ydr, ta_slot_chair.ydr, ta_slot.ytyp
#       ./ta_slot.blend（Blender で開いて直せる）、./preview/*.png（確認用の描画）
# 台の正面は -Y（座る人は +Y を向く）。原点は床の中心
import bpy, bmesh, json, math, os, importlib
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TEX = os.path.join(HERE, "tex")
STREAM = os.path.join(ROOT, "stream")
PREVIEW = os.path.join(HERE, "preview")
os.makedirs(STREAM, exist_ok=True)
os.makedirs(PREVIEW, exist_ok=True)

SZ = "bl_ext.user_default.sollumz"
importlib.import_module(SZ)
from bl_ext.user_default.sollumz.sollumz_properties import SollumType
from bl_ext.user_default.sollumz.ydr.shader_materials import create_shader
from bl_ext.user_default.sollumz.tools.blenderhelper import create_empty_object, create_blender_object
from bl_ext.user_default.sollumz.tools.drawablehelper import convert_obj_to_drawable
from bl_ext.user_default.sollumz.tools.boundhelper import apply_flag_preset
from bl_ext.user_default.sollumz.tools.meshhelper import create_box_from_extents
from bl_ext.user_default.sollumz.ybn import collision_materials as cm

LAYOUT = json.load(open(os.path.join(TEX, "layout.json"), encoding="utf-8"))
STRIPS = LAYOUT["_strips"]
N = 21

# 何もない場面から始める
for o in list(bpy.data.objects):
    bpy.data.objects.remove(o)
for m in list(bpy.data.meshes):
    bpy.data.meshes.remove(m)


# ---------------------------------------------------------------------------
# 材質（0 = 本体、1 = 光る面、2 = リール）
# ---------------------------------------------------------------------------
def image(name):
    path = os.path.join(TEX, name + ".dds")
    im = bpy.data.images.load(path, check_existing=True)
    im.name = name
    return im


def material(shader, tex, emissive=None, name=None):
    mat = create_shader(shader)
    if name:
        mat.name = name
    node = mat.node_tree.nodes.get("DiffuseSampler")
    node.image = image(tex)
    node.texture_properties.embedded = True
    if emissive is not None:
        mat.node_tree.nodes.get("emissiveMultiplier").set("X", emissive)
    return mat


MAT_BODY, MAT_GLOW, MAT_REEL = 0, 1, 2


def uvrect(name, size=(1024, 1024)):
    x, y, w, h = LAYOUT[name]
    W, H = size
    return (x / W, 1 - (y + h) / H, (x + w) / W, 1 - y / H)  # u0, v0, u1, v1（Blender は下が v=0）


# ---------------------------------------------------------------------------
# 形を足していく道具
# ---------------------------------------------------------------------------
class Builder:
    def __init__(self):
        self.bm = bmesh.new()
        self.uv = self.bm.loops.layers.uv.new("UVMap 0")

    def quad(self, ps, uvs, mat, outward=None, smooth=False):
        vs = [self.bm.verts.new(p) for p in ps]
        f = self.bm.faces.new(vs)
        f.material_index = mat
        f.smooth = smooth
        f.normal_update()
        uvmap = {v: uv for v, uv in zip(vs, uvs)}
        if outward is not None and f.normal.dot(outward) < 0:
            f.normal_flip()
        for loop in f.loops:
            loop[self.uv].uv = uvmap[loop.vert]
        return f

    # 箱。faces は { 'front': (rect名, 材質), ... }、無い面は default。skip の面は作らない
    def box(self, mn, mx, faces=None, default=("sw_black", MAT_BODY), skip=(), inward=False):
        faces = faces or {}
        x0, y0, z0 = mn
        x1, y1, z1 = mx
        # 面ごとの 4 点（左下・右下・右上・左上、外から見て）と、外向き
        defs = {
            "front": ([(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)], Vector((0, -1, 0))),
            "back": ([(x1, y1, z0), (x0, y1, z0), (x0, y1, z1), (x1, y1, z1)], Vector((0, 1, 0))),
            "right": ([(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)], Vector((1, 0, 0))),
            "left": ([(x0, y1, z0), (x0, y0, z0), (x0, y0, z1), (x0, y1, z1)], Vector((-1, 0, 0))),
            "top": ([(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)], Vector((0, 0, 1))),
            "bottom": ([(x0, y1, z0), (x1, y1, z0), (x1, y0, z0), (x0, y0, z0)], Vector((0, 0, -1))),
        }
        for k, (ps, n) in defs.items():
            if k in skip:
                continue
            rect, mat = faces.get(k, default)
            u0, v0, u1, v1 = uvrect(rect) if isinstance(rect, str) else rect
            uvs = [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]
            self.quad(ps, uvs, mat, -n if inward else n)

    # 円柱。axis は 'X' / 'Y' / 'Z'。side_uv(t, a) で側面の UV（t: 軸方向 0〜1、a: 角度 0〜1）
    def cylinder(self, c, axis, r, length, seg, side, cap, cap2=None, side_uv=None, smooth=True, angle0=0.0):
        c = Vector(c)

        def pt(t, a):
            th = angle0 + a * 2 * math.pi
            s = (t - 0.5) * length
            if axis == "Z":
                return c + Vector((r * math.sin(th), -r * math.cos(th), s))
            if axis == "X":
                return c + Vector((s, -r * math.cos(th), r * math.sin(th)))
            return c + Vector((r * math.sin(th), s, r * math.cos(th)))  # Y

        def center(t):
            s = (t - 0.5) * length
            return c + (Vector((0, 0, s)) if axis == "Z" else Vector((s, 0, 0)) if axis == "X" else Vector((0, s, 0)))

        start = len(self.bm.verts)
        srect, smat = side
        su0, sv0, su1, sv1 = uvrect(srect) if isinstance(srect, str) else srect
        for k in range(seg):
            a0, a1 = k / seg, (k + 1) / seg
            ps = [pt(0, a0), pt(1, a0), pt(1, a1), pt(0, a1)]
            if side_uv:
                uvs = [side_uv(0, a0), side_uv(1, a0), side_uv(1, a1), side_uv(0, a1)]
            else:
                uvs = [(su0, sv0), (su1, sv0), (su1, sv1), (su0, sv1)]
            mid = (ps[0] + ps[2]) / 2
            out = mid - center(0.5)
            self.quad(ps, uvs, smat, out, smooth)
        # ふた（扇形を四角で近似せず、三角で作る）
        for t, capdef in ((1, cap), (0, cap2 or cap)):
            if capdef is None:
                continue
            crect, cmat = capdef
            u0, v0, u1, v1 = uvrect(crect) if isinstance(crect, str) else crect
            cu, cv = (u0 + u1) / 2, (v0 + v1) / 2
            n = (center(1) - center(0)).normalized() * (1 if t == 1 else -1)
            for k in range(seg):
                a0, a1 = k / seg, (k + 1) / seg
                p0, p1 = pt(t, a0), pt(t, a1)
                vs = [self.bm.verts.new(center(t)), self.bm.verts.new(p0), self.bm.verts.new(p1)]
                f = self.bm.faces.new(vs)
                f.material_index = cmat
                f.normal_update()
                if f.normal.dot(n) < 0:
                    f.normal_flip()
                uvm = {
                    vs[0]: (cu, cv),
                    vs[1]: (cu + math.sin(a0 * 2 * math.pi) * (u1 - u0) / 2, cv - math.cos(a0 * 2 * math.pi) * (v1 - v0) / 2),
                    vs[2]: (cu + math.sin(a1 * 2 * math.pi) * (u1 - u0) / 2, cv - math.cos(a1 * 2 * math.pi) * (v1 - v0) / 2),
                }
                for loop in f.loops:
                    loop[self.uv].uv = uvm[loop.vert]
        # 同じ位置の点をまとめる（UV は面ごとに残る）。側面をなめらかにするため
        bmesh.ops.remove_doubles(self.bm, verts=list(self.bm.verts)[start:], dist=1e-5)

    def sphere(self, c, r, seg, ring, rect, mat):
        c = Vector(c)
        u0, v0, u1, v1 = uvrect(rect)
        start = len(self.bm.verts)
        for i in range(ring):
            for k in range(seg):
                ps = []
                for (ii, kk) in ((i, k), (i, k + 1), (i + 1, k + 1), (i + 1, k)):
                    phi = math.pi * ii / ring
                    th = 2 * math.pi * kk / seg
                    ps.append(c + Vector((r * math.sin(phi) * math.cos(th), r * math.sin(phi) * math.sin(th), r * math.cos(phi))))
                mid = sum(ps, Vector()) / 4
                self.quad(ps, [(u0, v0), (u1, v0), (u1, v1), (u0, v1)], mat, mid - c, True)
        bmesh.ops.remove_doubles(self.bm, verts=list(self.bm.verts)[start:], dist=1e-6)

    def to_object(self, name, mats):
        # 面積 0 の面（球の極）を消す
        bmesh.ops.dissolve_degenerate(self.bm, edges=self.bm.edges, dist=1e-7)
        me = bpy.data.meshes.new(name)
        self.bm.to_mesh(me)
        self.bm.free()
        # 頂点カラー（Sollumz の shader が使う）。白で埋める
        col = me.color_attributes.new(name="Color 1", type="BYTE_COLOR", domain="CORNER")
        for d in col.data:
            d.color = (1.0, 1.0, 1.0, 1.0)
        for m in mats:
            me.materials.append(m)
        obj = bpy.data.objects.new(name, me)
        bpy.context.collection.objects.link(obj)
        return obj


def collision_index(name):
    for i, m in enumerate(cm.collisionmats):
        if m.name == name:
            return i
    return 0


def add_bounds(drawable, boxes, material_name):
    comp = create_empty_object(SollumType.BOUND_COMPOSITE)
    comp.name = drawable.name + ".col"
    comp.parent = drawable
    mat = cm.create_collision_material_from_index(collision_index(material_name))
    for i, (mn, mx) in enumerate(boxes):
        b = create_blender_object(SollumType.BOUND_BOX)
        b.name = f"{drawable.name}.box{i}"
        c = (Vector(mn) + Vector(mx)) / 2
        create_box_from_extents(b.data, Vector(mn) - c, Vector(mx) - c)
        b.location = c
        b.parent = comp
        b.data.materials.append(mat)
        apply_flag_preset(b, "General (Default)")
    return comp


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
# ytyp
# ---------------------------------------------------------------------------
bpy.ops.sollumz.createytyp()
ytyp = bpy.context.scene.ytyps[-1]
ytyp.name = "ta_slot"
for d in (machine, chair):
    for o in bpy.context.selected_objects:
        o.select_set(False)
    d.select_set(True)
    bpy.context.view_layer.objects.active = d
    bpy.ops.sollumz.createarchetypefromselected()
for a in ytyp.archetypes:
    a.lod_dist = 120.0
    a.hd_texture_dist = 40.0
    print("archetype", a.name, a.texture_dictionary, a.physics_dictionary)

# 書き出し（椅子の位置は原点に戻す）
chair.location = (0.0, 0.0, 0.0)
bpy.context.view_layer.update()
res = bpy.ops.sollumz.export_assets(directory=STREAM, direct_export=True, use_custom_settings=True,
                                    target_formats={"NATIVE"}, target_versions={"GEN8"}, limit_to_selected=False,
                                    export_ytyps=True, export_ytyps_include="ALL")
print("export", res, sorted(os.listdir(STREAM)))
chair.location = (0.0, -0.80, 0.0)
# 公開してもよいよう、データだけを相対パスで保存する（save_as_mainfile だと画面の情報と PC のフォルダの絶対パスも入る）
# テクスチャの場所は .blend から見た相対パスにする。パスの入れ物には前の絶対パスの残りが後ろに残り、そのまま書かれるので、先に埋めてから入れる
for im in bpy.data.images:
    if im.filepath:
        rel = "//tex/" + os.path.basename(im.filepath)
        im.filepath_raw = "_" * 1000
        im.filepath_raw = rel
bpy.data.libraries.write(os.path.join(HERE, "ta_slot.blend"), {bpy.context.scene}, path_remap="NONE", compress=True)

# ---------------------------------------------------------------------------
# 確認用の描画（Workbench・テクスチャ表示）
# ---------------------------------------------------------------------------
for o in bpy.data.objects:
    if o.sollum_type in (SollumType.BOUND_COMPOSITE, SollumType.BOUND_BOX):
        o.hide_render = True
scene = bpy.context.scene
scene.render.engine = "BLENDER_WORKBENCH"
scene.display.shading.light = "STUDIO"
scene.display.shading.color_type = "TEXTURE"
scene.display.shading.show_cavity = True
scene.render.resolution_x, scene.render.resolution_y = 900, 1200
scene.world = scene.world or bpy.data.worlds.new("w")
cam_data = bpy.data.cameras.new("cam")
cam = bpy.data.objects.new("cam", cam_data)
bpy.context.collection.objects.link(cam)
scene.camera = cam
# PNG に .blend の絶対パスや日時を書き込まない
for k in dir(scene.render):
    if k.startswith("use_stamp"):
        setattr(scene.render, k, False)


def shot(name, loc, target, lens=35):
    cam.location = loc
    d = Vector(target) - Vector(loc)
    cam.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    cam_data.lens = lens
    scene.render.filepath = os.path.join(PREVIEW, name + ".png")
    bpy.ops.render.render(write_still=True)


shot("front", (0.0, -2.6, 1.25), (0.0, 0.0, 1.0), 32)
shot("three_quarter", (1.7, -2.2, 1.7), (0.0, -0.3, 0.9), 30)
shot("reels", (0.0, -0.75, 1.27), (0.0, -0.2, 1.25), 40)
shot("chair", (1.0, -1.9, 0.9), (0.0, -0.8, 0.5), 35)
print("done")
