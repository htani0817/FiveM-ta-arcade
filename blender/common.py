# -*- coding: utf-8 -*-
# 台のモデルを Blender で組み立てて Sollumz で書き出すための共通の道具
# build_models.py（パチスロ）と build_pachi.py（パチンコ）が使う。Blender の中からだけ読める
import bpy, bmesh, math, os, importlib
from mathutils import Vector

SZ = "bl_ext.user_default.sollumz"
importlib.import_module(SZ)
from bl_ext.user_default.sollumz.sollumz_properties import SollumType
from bl_ext.user_default.sollumz.ydr.shader_materials import create_shader
from bl_ext.user_default.sollumz.tools.blenderhelper import create_empty_object, create_blender_object
from bl_ext.user_default.sollumz.tools.drawablehelper import convert_obj_to_drawable
from bl_ext.user_default.sollumz.tools.boundhelper import apply_flag_preset
from bl_ext.user_default.sollumz.tools.meshhelper import create_box_from_extents
from bl_ext.user_default.sollumz.ybn import collision_materials as cm

# 材質の番号（0 = 本体、1 = 光る面。2 以降は台ごとに決める）
MAT_BODY, MAT_GLOW = 0, 1


# 何もない場面から始める
def reset_scene():
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o)
    for m in list(bpy.data.meshes):
        bpy.data.meshes.remove(m)


# ---------------------------------------------------------------------------
# 材質
# ---------------------------------------------------------------------------
def image(tex_dir, name):
    path = os.path.join(tex_dir, name + ".dds")
    im = bpy.data.images.load(path, check_existing=True)
    im.name = name
    return im


def material(tex_dir, shader, tex, emissive=None, name=None):
    mat = create_shader(shader)
    if name:
        mat.name = name
    node = mat.node_tree.nodes.get("DiffuseSampler")
    node.image = image(tex_dir, tex)
    node.texture_properties.embedded = True
    if emissive is not None:
        mat.node_tree.nodes.get("emissiveMultiplier").set("X", emissive)
    return mat


# ---------------------------------------------------------------------------
# 形を足していく道具。layout はアトラスの中の場所の表（make_*_textures.py が書く layout.json）
# ---------------------------------------------------------------------------
class Builder:
    def __init__(self, layout, size=(1024, 1024)):
        self.layout = layout
        self.size = size
        self.bm = bmesh.new()
        self.uv = self.bm.loops.layers.uv.new("UVMap 0")

    def uvrect(self, name):
        x, y, w, h = self.layout[name]
        W, H = self.size
        return (x / W, 1 - (y + h) / H, (x + w) / W, 1 - y / H)  # u0, v0, u1, v1（Blender は下が v=0）

    def _rect(self, rect):
        return self.uvrect(rect) if isinstance(rect, str) else rect

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
            u0, v0, u1, v1 = self._rect(rect)
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
        su0, sv0, su1, sv1 = self._rect(srect)
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
            u0, v0, u1, v1 = self._rect(crect)
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
        u0, v0, u1, v1 = self._rect(rect)
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

    # できた形を Sollumz の drawable にする
    def to_drawable(self, name, mats):
        d = convert_obj_to_drawable(self.to_object(name, mats))
        d.name = name
        return d


# ---------------------------------------------------------------------------
# コリジョン（箱の集まり）
# ---------------------------------------------------------------------------
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
# ytyp・書き出し・保存
# ---------------------------------------------------------------------------
def make_ytyp(name, drawables):
    bpy.ops.sollumz.createytyp()
    ytyp = bpy.context.scene.ytyps[-1]
    ytyp.name = name
    for d in drawables:
        for o in bpy.context.selected_objects:
            o.select_set(False)
        d.select_set(True)
        bpy.context.view_layer.objects.active = d
        bpy.ops.sollumz.createarchetypefromselected()
    for a in ytyp.archetypes:
        a.lod_dist = 120.0
        a.hd_texture_dist = 40.0
        print("archetype", a.name, a.texture_dictionary, a.physics_dictionary)
    return ytyp


# 場面にある drawable と ytyp を全部書き出す（どれも原点に置いておくこと）
def export(stream_dir):
    bpy.context.view_layer.update()
    res = bpy.ops.sollumz.export_assets(directory=stream_dir, direct_export=True, use_custom_settings=True,
                                        target_formats={"NATIVE"}, target_versions={"GEN8"}, limit_to_selected=False,
                                        export_ytyps=True, export_ytyps_include="ALL")
    print("export", res, sorted(os.listdir(stream_dir)))
    return res


# 公開してもよいよう、データだけを相対パスで保存する（save_as_mainfile だと画面の情報と PC のフォルダの絶対パスも入る）
# テクスチャの場所は .blend から見た相対パスにする。パスの入れ物には前の絶対パスの残りが後ろに残り、そのまま書かれるので、先に埋めてから入れる
def save_blend(path):
    for im in bpy.data.images:
        if im.filepath:
            rel = "//tex/" + os.path.basename(im.filepath)
            im.filepath_raw = "_" * 1000
            im.filepath_raw = rel
    bpy.data.libraries.write(path, {bpy.context.scene}, path_remap="NONE", compress=True)


# ---------------------------------------------------------------------------
# 確認用の描画（Workbench・テクスチャ表示）。戻り値の shot(name, loc, target, lens) で撮る
# ---------------------------------------------------------------------------
def setup_render(preview_dir):
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
        scene.render.filepath = os.path.join(preview_dir, name + ".png")
        bpy.ops.render.render(write_still=True)

    return shot
