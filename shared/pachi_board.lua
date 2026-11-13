-- ta-arcade のパチンコ「宵花火」の盤面: 釘・風車・役物・入賞口の並び（単位はピクセル。左上が 0,0、下が +y）
-- サーバーの物理計算（server/pachi_physics.lua）と、台の画面（html/pachi.js）、台のテクスチャ（blender/make_pachi_textures.py）が同じ並びを使う
-- 並びを変えたら tests/pachi-rates.js で入賞の割合を測り直し、node tests/lua-run.js pachi-export.lua で画面の見本とテクスチャ用の JSON を作り直す
PachiBoard = {}
local B = PachiBoard

B.W, B.H = 560, 584
B.cx, B.cy = 280, 292
B.R = 262          -- 盤面の円（絵）
B.wall = 254       -- 玉が当たる外レールの半径
B.ballR = 7.0      -- 玉の半径（盤面の直径 524 が実物の約 39cm、玉は 11mm）
B.nailR = 2.5      -- 釘の頭の半径

-- 液晶（役物）。玉は入れない箱
B.lcd = { x = 160, y = 122, w = 240, h = 146 }
-- 液晶の屋根（山形。乗った玉は左右へ転がる）。{ x1, y1, x2, y2 } の線
B.segments = {
    { 156, 122, 280, 102 },
    { 280, 102, 404, 122 },
}

-- 入賞口
--   heso: まん中のヘソ、denchu: 右の電チュー（確変・時短中に開く）、attacker: 右下のアタッカー（大当たり中に開く）
--   general: 左下の一般入賞口、out: アウト口
B.pocket = {
    heso = { x = 280, y = 374, r = 6.5 },
    denchu = { x = 436, y = 392, w = 9, h = 7 },
    attacker = { x = 398, y = 468, w = 48, h = 7 },
    general = { { x = 204, y = 456, r = 5.5 } },
    out = { x = 280, y = 540, w = 34 },
}

-- 打ち出し。玉は左の発射レールの出口から、外レールに沿って上へ飛び出す
--   angle: 出口の位置（度。右が 0、下が 90、左が 180、上が 270）
--   vmin / vmax: ハンドルの強さ 0〜100 に対する速さ（ピクセル / 秒）
B.launch = { angle = 200, vmin = 1050, vmax = 2500 }

-- 右上の返しゴム（強く打った玉はここに当たって右へ落ちる）
B.rubber = { x = 418, y = 84, r = 10 }

-- 風車（大きめの釘として当たり、当たった玉を横へ弾く）
B.windmills = { { x = 116, y = 318, r = 8 }, { x = 470, y = 300, r = 8 } }

---------------------------------------------------------------------------
-- 釘
---------------------------------------------------------------------------
local nails = {}
local function nail(x, y) nails[#nails + 1] = { x = x, y = y } end
-- (x1,y1) から (x2,y2) まで n 本を等間隔に打つ。skip に入れた番号（1 から）は打たない（こぼし）
local function row(x1, y1, x2, y2, n, skip)
    for i = 0, n - 1 do
        if not (skip and skip[i + 1]) then
            local t = n > 1 and i / (n - 1) or 0
            nail(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t)
        end
    end
end

-- 天釘（液晶の左上。ここの手前に落とすのが「ぶっこみ」）
row(168, 90, 240, 96, 4)
-- 天の右側（液晶の上を越えた玉を散らす）
row(286, 84, 382, 80, 4)

-- 左の寄り釘（互い違いに打って玉を散らし、風車へ寄せる）
for i = 0, 5 do
    local y = 128 + i * 30
    local x0 = (i % 2 == 0) and 62 or 78
    for x = x0, 146, 32 do
        if (x - B.cx) ^ 2 + (y - B.cy) ^ 2 < (B.wall - 14) ^ 2 then nail(x, y) end
    end
end
-- 風車の上のハの字
row(84, 296, 100, 306, 2)
row(148, 296, 132, 306, 2)

-- 道釘（風車の下からヘソへ、右下がりの列。6 番と 9 番を抜いて、こぼれる所を作る）
-- ヘソへの入りやすさは、命釘の間隔よりも、このこぼしの数と場所で大きく変わる（tests/pachi-rates.js で測った）
row(134, 332, 240, 362.5, 12, { [6] = true, [9] = true })
-- 道釘から落ちた玉を受ける下の列（左へ流してアウトへ）
row(236, 398, 160, 424, 7)

-- ジャンプ釘（道釘の終わりから少し離して打つ。勢いのある玉はここで跳ねて命釘の間へ、遅い玉は手前のすき間からこぼれる）
nail(259, 371)
-- 命釘（ヘソの上の 2 本。この間隔で回り方が決まる）と、ヘソの横の受け
B.hesoGap = 16.2 -- 命釘の頭と頭の間（玉の直径は 14）
nail(B.pocket.heso.x - B.hesoGap / 2 - B.nailR, 358)
nail(B.pocket.heso.x + B.hesoGap / 2 + B.nailR, 358)
nail(B.pocket.heso.x - 12, 372)
nail(B.pocket.heso.x + 12, 372)
-- ヘソの右（右から来た玉も少しは寄る）
row(302, 372, 330, 366, 3)

-- 左下（一般入賞口のまわりとアウトへの流れ）
for i = 0, 3 do
    local y = 430 + i * 30
    local x0 = (i % 2 == 0) and 70 or 86
    for x = x0, 250, 34 do
        local ok = (x - B.cx) ^ 2 + (y - B.cy) ^ 2 < (B.wall - 14) ^ 2
        for _, g in ipairs(B.pocket.general) do
            if math.abs(x - g.x) < 20 and math.abs(y - g.y) < 24 then ok = false end
        end
        if math.abs(x - B.pocket.out.x) < 44 and y > 500 then ok = false end
        if ok then nail(x, y) end
    end
end
-- 一般入賞口の受け（左右の 2 本。この間を通った玉だけが入る）
for _, g in ipairs(B.pocket.general) do
    nail(g.x - 11, g.y - 2)
    nail(g.x + 11, g.y - 2)
end

-- 右（右打ちの玉が落ちる所。散らしてから電チューとアタッカーへ寄せる）
for i = 0, 5 do
    local y = 126 + i * 30
    local x0 = (i % 2 == 0) and 424 or 440
    for x = x0, 510, 32 do
        if (x - B.cx) ^ 2 + (y - B.cy) ^ 2 < (B.wall - 14) ^ 2 and not (math.abs(x - 470) < 14 and math.abs(y - 300) < 14) then nail(x, y) end
    end
end
-- 電チューへ寄せる列（右から左下へ）と、電チューの左の受け
row(508, 336, 458, 372, 6, { [4] = true })
row(408, 352, 418, 372, 2)
-- アタッカーへ寄せる列
row(492, 400, 456, 444, 6)
row(326, 412, 344, 448, 4)
-- アタッカーの右下（こぼれた玉をアウトへ）
row(462, 470, 452, 492, 2)

B.nails = nails

-- 画面やテクスチャへ渡す形（数字だけの表）
function B.export()
    return {
        W = B.W, H = B.H, cx = B.cx, cy = B.cy, R = B.R, wall = B.wall, ballR = B.ballR, nailR = B.nailR,
        lcd = B.lcd, segments = B.segments, pocket = B.pocket, launch = B.launch, rubber = B.rubber, windmills = B.windmills, nails = B.nails,
    }
end
