# -*- coding: utf-8 -*-
# design/svg の SVG を headless Chromium で PNG にする（2倍で描いて元の大きさに縮小）
# py -3 render.py <svgフォルダ> <png出力フォルダ>
import os, re, subprocess, sys
from PIL import Image

SHELL = os.path.expandvars(r"%LOCALAPPDATA%\ms-playwright\chromium_headless_shell-1148\chrome-win\headless_shell.exe")
svg_dir, out_dir = sys.argv[1], sys.argv[2]
os.makedirs(out_dir, exist_ok=True)
tmp = os.path.join(out_dir, "_tmp.png")
for f in sorted(os.listdir(svg_dir)):
    if not f.endswith(".svg"):
        continue
    src = open(os.path.join(svg_dir, f), encoding="utf-8").read()
    w, h = (int(v) for v in re.search(r'width="(\d+)" height="(\d+)"', src).groups())
    url = "file:///" + os.path.abspath(os.path.join(svg_dir, f)).replace("\\", "/")
    subprocess.run([SHELL, "--headless", "--disable-gpu", f"--screenshot={tmp}", f"--window-size={w},{h}",
                    "--force-device-scale-factor=2", "--default-background-color=00000000", "--hide-scrollbars", url],
                   check=True, capture_output=True)
    im = Image.open(tmp).convert("RGBA").resize((w * 2, h * 2), Image.LANCZOS)
    # NUI 用は 2 倍のまま（高解像度の画面でもぼやけないように）
    im.save(os.path.join(out_dir, f[:-4] + ".png"), optimize=True)
os.remove(tmp)
print("ok")
