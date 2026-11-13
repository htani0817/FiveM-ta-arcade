-- ta-arcade のパチンコ「宵花火」の物理計算: 玉を 1 個、打ち出しから入賞口かアウト口まで動かす
-- 重力と、釘・風車・返しゴム・液晶・外レール・閉じた入賞口への衝突だけで動かす（行き先を決めるくじは引かない）
-- FiveM の関数は使わない（tests/ からそのまま動かす）。サーバーだけが読む
PachiPhysics = {}
local P = PachiPhysics
local B = PachiBoard

local sqrt, floor, abs, min, max = math.sqrt, math.floor, math.abs, math.min, math.max

-- 数字（単位はピクセルと秒）
P.G = 9000.0          -- 重力
P.DT = 1.0 / 600.0    -- 1 歩の時間
P.MAX_TIME = 9.0      -- これより長く残った玉はアウトにする
P.SAMPLE = 12         -- 何歩ごとに軌道を残すか（600 / 12 = 1 秒に 50 点）
P.E_NAIL = 0.52       -- 釘のはね返り
P.E_WALL = 0.22       -- 外レール・役物のはね返り
P.E_RUBBER = 0.30     -- 返しゴム
P.FRICTION = 0.97     -- 強く当たったときに、面に沿う向きの速さに掛ける
P.REST = 70.0         -- これより弱い当たりは「乗っているだけ」とみなし、摩擦を掛けず、はね返さない（玉が釘の上を転がれるように）
P.VMAX = 3300.0       -- 速さの上限（1 歩で玉の半径より進ませない）

---------------------------------------------------------------------------
-- 当たるもの（丸）を升目に分けておく
---------------------------------------------------------------------------
local CELL = 32
local circles = {} -- { x, y, r（玉の半径を足した後）, e, kind }
local grid = {}

local function addCircle(x, y, r, e, kind)
    local c = { x = x, y = y, r = r + B.ballR, e = e, kind = kind }
    circles[#circles + 1] = c
    local x0, x1 = floor((x - c.r) / CELL), floor((x + c.r) / CELL)
    local y0, y1 = floor((y - c.r) / CELL), floor((y + c.r) / CELL)
    for gy = y0, y1 do
        for gx = x0, x1 do
            local k = gy * 64 + gx
            local cell = grid[k]
            if not cell then cell = {}; grid[k] = cell end
            cell[#cell + 1] = c
        end
    end
end

function P.build()
    circles, grid = {}, {}
    for _, n in ipairs(B.nails) do addCircle(n.x, n.y, B.nailR, P.E_NAIL, 'nail') end
    for _, w in ipairs(B.windmills) do addCircle(w.x, w.y, w.r, P.E_NAIL, 'mill') end
    addCircle(B.rubber.x, B.rubber.y, B.rubber.r, P.E_RUBBER, 'rubber')
end
P.build()

---------------------------------------------------------------------------
-- 箱（液晶・閉じた電チュー・閉じたアタッカー）。玉の中心が入れない範囲を返す
---------------------------------------------------------------------------
local function boxOf(cx, cy, hw, hh)
    return { x0 = cx - hw - B.ballR, x1 = cx + hw + B.ballR, y0 = cy - hh - B.ballR, y1 = cy + hh + B.ballR }
end
local LCD = { x0 = B.lcd.x - B.ballR, x1 = B.lcd.x + B.lcd.w + B.ballR, y0 = B.lcd.y - B.ballR, y1 = B.lcd.y + B.lcd.h + B.ballR }
local ATTACKER = boxOf(B.pocket.attacker.x, B.pocket.attacker.y, B.pocket.attacker.w, B.pocket.attacker.h)

-- 線（液晶の屋根）。いちばん近い点から押し出してはね返す
local function hitSegment(seg, s)
    local x1, y1, x2, y2 = seg[1], seg[2], seg[3], seg[4]
    local ex, ey = x2 - x1, y2 - y1
    local t = ((s.x - x1) * ex + (s.y - y1) * ey) / (ex * ex + ey * ey)
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local dx, dy = s.x - (x1 + ex * t), s.y - (y1 + ey * t)
    local d2 = dx * dx + dy * dy
    local r = B.ballR
    if d2 >= r * r or d2 < 1e-9 then return end
    local d = sqrt(d2)
    local nx, ny = dx / d, dy / d
    s.x, s.y = s.x + nx * (r - d), s.y + ny * (r - d)
    local vn = s.vx * nx + s.vy * ny
    if vn < 0 then
        local tx, ty = -ny, nx
        local vt = s.vx * tx + s.vy * ty
        if vn < -P.REST then
            vt = vt * P.FRICTION
            vn = -vn * P.E_WALL
        else
            vn = 0.0
        end
        s.vx, s.vy = nx * vn + tx * vt, ny * vn + ty * vt
    end
end

-- 箱の中に入っていたら、いちばん近い面へ押し出してはね返す
local function hitBox(b, s)
    local x, y = s.x, s.y
    if x <= b.x0 or x >= b.x1 or y <= b.y0 or y >= b.y1 then return false end
    local dl, dr, dt, db = x - b.x0, b.x1 - x, y - b.y0, b.y1 - y
    local m = min(dl, dr, dt, db)
    if m == dt then
        s.y = b.y0
        if s.vy > 0 then s.vy = -s.vy * P.E_WALL end
    elseif m == db then
        s.y = b.y1
        if s.vy < 0 then s.vy = -s.vy * P.E_WALL end
    elseif m == dl then
        s.x = b.x0
        if s.vx > 0 then s.vx = -s.vx * P.E_WALL end
    else
        s.x = b.x1
        if s.vx < 0 then s.vx = -s.vx * P.E_WALL end
    end
    return true
end

---------------------------------------------------------------------------
-- 玉を 1 個動かす
--   power     ハンドルの強さ 0〜100
--   rnd       0〜1 の乱数を返す関数（打ち出しのむらに使う）
--   gates     denchu: 電チューが開いているか、attacker(t): 打ってから t ミリ秒後にアタッカーへ入れるか（入れたら数える）
-- 戻り値: { to = 行き先, t = かかった時間（ミリ秒）, path = 軌道（x*2, y*2 を並べた整数）, hits = 釘に当たった点の番号 }
--   to は miss / heso / denchu / attacker / general
---------------------------------------------------------------------------
function P.simulate(power, rnd, gates)
    power = max(0, min(100, power))
    local L = B.launch
    -- 打ち出しのむら（速さ ±2.5%。同じ強さでも落ちる所が少しずつずれる）
    local v0 = (L.vmin + (L.vmax - L.vmin) * power / 100.0) * (1.0 + (rnd() - 0.5) * 0.05)
    local a = L.angle * math.pi / 180.0
    local ca, sa = math.cos(a), math.sin(a)
    local rr = B.wall - B.ballR - 0.5
    local s = { x = B.cx + ca * rr, y = B.cy + sa * rr, vx = -sa * v0, vy = ca * v0 }
    local millSign = rnd() < 0.5 and -1.0 or 1.0
    local kick = rnd()

    local dt, g = P.DT, P.G
    local path, hits = {}, {}
    local np, nh = 0, 0
    local steps = floor(P.MAX_TIME / dt)
    local to = 'miss'
    local attackerClosed = false -- 一度「閉じている」と決まったら、この玉には最後まで閉じた箱として当たる
    local slow = 0
    local lastX, lastY = s.x, s.y
    local wallR = B.wall - B.ballR
    local heso, out, generals = B.pocket.heso, B.pocket.out, B.pocket.general
    local dn, at = B.pocket.denchu, B.pocket.attacker
    local step = 0

    while step < steps do
        step = step + 1
        s.vy = s.vy + g * dt
        local sp2 = s.vx * s.vx + s.vy * s.vy
        if sp2 > P.VMAX * P.VMAX then
            local k = P.VMAX / sqrt(sp2)
            s.vx, s.vy = s.vx * k, s.vy * k
        end
        s.x = s.x + s.vx * dt
        s.y = s.y + s.vy * dt

        -- 釘・風車・返しゴム
        local cell = grid[floor(s.y / CELL) * 64 + floor(s.x / CELL)]
        if cell then
            for i = 1, #cell do
                local c = cell[i]
                local dx, dy = s.x - c.x, s.y - c.y
                local d2 = dx * dx + dy * dy
                if d2 < c.r * c.r and d2 > 1e-9 then
                    local d = sqrt(d2)
                    local nx, ny = dx / d, dy / d
                    s.x, s.y = c.x + nx * c.r, c.y + ny * c.r
                    local vn = s.vx * nx + s.vy * ny
                    if vn < 0 then
                        local tx, ty = -ny, nx
                        local vt = s.vx * tx + s.vy * ty
                        if vn < -P.REST then
                            vt = vt * P.FRICTION
                            if c.kind == 'mill' then vt = vt + millSign * 140.0 end
                            vn = -vn * c.e
                            if vn > 150 and nh < 48 then nh = nh + 1; hits[nh] = floor(step / P.SAMPLE) end
                        else
                            vn = 0.0
                        end
                        s.vx, s.vy = nx * vn + tx * vt, ny * vn + ty * vt
                    end
                end
            end
        end

        -- 外レール
        local dx, dy = s.x - B.cx, s.y - B.cy
        local d2 = dx * dx + dy * dy
        if d2 > wallR * wallR then
            local d = sqrt(d2)
            local nx, ny = dx / d, dy / d
            s.x, s.y = B.cx + nx * wallR, B.cy + ny * wallR
            local vn = s.vx * nx + s.vy * ny
            if vn > 0 then
                local tx, ty = -ny, nx
                local vt = (s.vx * tx + s.vy * ty) * 0.999
                vn = -vn * P.E_WALL
                s.vx, s.vy = nx * vn + tx * vt, ny * vn + ty * vt
            end
        end

        -- 液晶と屋根
        hitBox(LCD, s)
        for i = 1, #B.segments do hitSegment(B.segments[i], s) end

        -- 入賞口
        local hx, hy = s.x - heso.x, s.y - heso.y
        if hx * hx + hy * hy < heso.r * heso.r then to = 'heso' break end
        local gen = false
        for i = 1, #generals do
            local p = generals[i]
            local gx, gy = s.x - p.x, s.y - p.y
            if gx * gx + gy * gy < p.r * p.r then gen = true end
        end
        if gen then to = 'general' break end
        -- 電チュー: 開いていれば羽根の幅で拾う。閉じていれば、閉じた羽根（丸）に当たって弾かれる
        if gates.denchu then
            if abs(s.x - dn.x) < dn.w + 4 and abs(s.y - dn.y) < dn.h + 5 then to = 'denchu' break end
        else
            local ex, ey = s.x - dn.x, s.y - dn.y
            local e2, er = ex * ex + ey * ey, dn.w + B.ballR
            if e2 < er * er and e2 > 1e-9 then
                local e = sqrt(e2)
                local nx, ny = ex / e, ey / e
                s.x, s.y = dn.x + nx * er, dn.y + ny * er
                local vn = s.vx * nx + s.vy * ny
                if vn < 0 then s.vx, s.vy = s.vx - (1 + P.E_NAIL) * vn * nx, s.vy - (1 + P.E_NAIL) * vn * ny end
            end
        end
        -- アタッカー: 届いた時刻に開いているかを 1 回だけ聞く。閉じているときは盤面と面一なので、玉は前を素通りする
        if not attackerClosed and s.x > ATTACKER.x0 and s.x < ATTACKER.x1 and s.y > ATTACKER.y0 and s.y < ATTACKER.y1 then
            if gates.attacker and gates.attacker(step * dt * 1000.0) then
                to = 'attacker'
                break
            end
            attackerClosed = true
        end
        -- アウト口と、盤面の下
        if (s.y > out.y - 12 and abs(s.x - out.x) < out.w) or s.y > B.cy + wallR - 2 then break end

        -- 0.4 秒たってもほとんど動いていない玉（釘の間に引っ掛かった）は、横へ押して外す
        if step % 240 == 0 then
            local mx, my = s.x - lastX, s.y - lastY
            if mx * mx + my * my < 36 then
                kick = (kick * 9301.0 + 0.2113) % 1.0
                s.vx = s.vx + (kick < 0.5 and -1.0 or 1.0) * (160.0 + slow * 80.0)
                s.vy = s.vy - 120.0
                slow = slow + 1
            end
            lastX, lastY = s.x, s.y
        end

        if step % P.SAMPLE == 0 then
            path[np + 1] = floor(s.x * 2 + 0.5)
            path[np + 2] = floor(s.y * 2 + 0.5)
            np = np + 2
        end
    end
    -- 最後の位置
    path[np + 1] = floor(s.x * 2 + 0.5)
    path[np + 2] = floor(s.y * 2 + 0.5)
    return { to = to, t = floor(step * dt * 1000.0 + 0.5), path = path, hits = hits }
end
