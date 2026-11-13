-- ta-arcade のパチスロ「夜祭」のリール制御（サーバーとクライアントで同じものを使う）
-- サーバーは内部抽選で決めた「狙う役」を渡し、押した位置から止まる位置を決める。
-- クライアントは同じ計算で止まる位置を先に出して回転を止め、サーバーが同じ計算で答え合わせをする。

SlotEngine = {}
local E = SlotEngine

-- 図柄 R7=赤7 LN=提灯 BR=BAR BL=ベル SK=スイカ CH=チェリー RP=リプレイ
E.Symbols = { 'R7', 'LN', 'BR', 'BL', 'SK', 'CH', 'RP' }

-- リール配列（各21コマ）。位置 p で止まると 下段=p 中段=p+1 上段=p+2 が見える。
-- 回転中は p が増える向きに動く（図柄は上から下へ流れる）。押した位置から最大4コマ滑る。
-- 並びを変えたら tests/test-engine.js で取りこぼしと「当たっていない役が揃わないこと」を総当たりで確かめる。
E.Reels = {
    -- 左リール
    { 'RP', 'BL', 'CH', 'BL', 'LN', 'RP', 'BL', 'SK', 'CH', 'LN', 'RP', 'BL', 'RP', 'BL', 'R7', 'CH', 'BR', 'RP', 'BL', 'R7', 'SK' },
    -- 中リール
    { 'BR', 'BL', 'BR', 'SK', 'RP', 'R7', 'BL', 'LN', 'RP', 'SK', 'BL', 'BR', 'RP', 'BL', 'R7', 'LN', 'RP', 'SK', 'BL', 'CH', 'RP' },
    -- 右リール
    { 'CH', 'RP', 'BR', 'BL', 'SK', 'R7', 'RP', 'LN', 'BL', 'BR', 'RP', 'SK', 'BL', 'RP', 'R7', 'BL', 'BR', 'RP', 'SK', 'LN', 'BL' },
}
E.Size = 21
E.MaxSlip = 4

-- 有効ライン（行 1=上段 2=中段 3=下段、左・中・右の順）
E.Lines = {
    { 2, 2, 2 }, -- 中段
    { 1, 1, 1 }, -- 上段
    { 3, 3, 3 }, -- 下段
    { 1, 2, 3 }, -- 右下がり
    { 3, 2, 1 }, -- 右上がり
}

-- 役。sym の '*' はどれでもよい。pay は 1 ラインあたりの払い出し枚数
E.Combos = {
    replay = { sym = { 'RP', 'RP', 'RP' }, pay = 0, label = 'リプレイ' },
    bell   = { sym = { 'BL', 'BL', 'BL' }, pay = 8, label = 'ベル' },
    suika  = { sym = { 'SK', 'SK', 'SK' }, pay = 6, label = 'スイカ' },
    cherry = { sym = { 'CH', '*', '*' }, pay = 2, label = 'チェリー' },
    big    = { sym = { 'R7', 'R7', 'R7' }, pay = 0, label = 'BIG' },
    reg    = { sym = { 'LN', 'LN', 'LN' }, pay = 0, label = 'REG' },
}
E.ComboOrder = { 'replay', 'bell', 'suika', 'cherry', 'big', 'reg' }
E.BonusBellPay = 15 -- ボーナス中のベルの払い出し
E.MaxPay = 15        -- 1 ゲームの払い出しの上限

local N = E.Size

-- p は 0〜20。row 1=上段 2=中段 3=下段
function E.symbolAt(reel, p, row)
    return E.Reels[reel][((p + (3 - row)) % N) + 1]
end

-- 3 リールの位置から、揃った役の一覧を返す（{ combo=名前, line=番号 } の配列）
function E.evaluate(pos)
    local hits = {}
    for li, line in ipairs(E.Lines) do
        local s1 = E.symbolAt(1, pos[1], line[1])
        local s2 = E.symbolAt(2, pos[2], line[2])
        local s3 = E.symbolAt(3, pos[3], line[3])
        for _, name in ipairs(E.ComboOrder) do
            local c = E.Combos[name].sym
            if (c[1] == '*' or c[1] == s1) and (c[2] == '*' or c[2] == s2) and (c[3] == '*' or c[3] == s3) then
                hits[#hits + 1] = { combo = name, line = li }
            end
        end
    end
    return hits
end

-- 結果の採点。want は今回揃えてよい役の名前（nil ならハズレ）
-- bad = 揃ってはいけない役の数、hit = 狙う役が揃ったか
local function judge(pos, want)
    local bad, hit = 0, false
    for _, h in ipairs(E.evaluate(pos)) do
        if h.combo == want then hit = true else bad = bad + 1 end
    end
    return bad, hit
end

-- 残りのリールを均等な押し位置で止めたときの「安全に止まる確率」と「狙う役が揃う確率」
-- stopped は { [リール番号]=位置 }。メモ化して何度でも速く引けるようにする
local memo = {}

local function key(want, stopped)
    return (want or '-') .. ':' .. (stopped[1] or 'x') .. ',' .. (stopped[2] or 'x') .. ',' .. (stopped[3] or 'x')
end

local valueOf -- 前方宣言

-- reel を press で押したときに止める位置（0〜20）を決める
-- 選び方: 1) 当たっていない役が揃う確率が最も低い 2) 狙う役が揃う確率が最も高い 3) 滑りが少ない
function E.decide(want, stopped, reel, press)
    local bestPos, bestSafe, bestHit = nil, -1, -1
    for d = 0, E.MaxSlip do
        local p = (press + d) % N
        stopped[reel] = p
        local safe, hit = valueOf(want, stopped)
        stopped[reel] = nil
        if safe > bestSafe + 1e-9 or (math.abs(safe - bestSafe) <= 1e-9 and hit > bestHit + 1e-9) then
            bestPos, bestSafe, bestHit = p, safe, hit
        end
    end
    return bestPos
end

valueOf = function(want, stopped)
    local remaining = {}
    for r = 1, 3 do
        if stopped[r] == nil then remaining[#remaining + 1] = r end
    end
    if #remaining == 0 then
        local bad, hit = judge(stopped, want)
        return bad == 0 and 1 or 0, (bad == 0 and hit) and 1 or 0
    end
    local k = key(want, stopped)
    local m = memo[k]
    if m then return m[1], m[2] end
    -- 残りのどのリールから押すかは半々とみなす
    local sSum, hSum, cnt = 0, 0, 0
    for _, r in ipairs(remaining) do
        for press = 0, N - 1 do
            local p = E.decide(want, stopped, r, press)
            stopped[r] = p
            local s, h = valueOf(want, stopped)
            stopped[r] = nil
            sSum, hSum, cnt = sSum + s, hSum + h, cnt + 1
        end
    end
    local s, h = sSum / cnt, hSum / cnt
    memo[k] = { s, h }
    return s, h
end

-- 第1停止の判断を全部計算してメモに入れておく（最初のゲームで引っかからないように）
-- step を渡すと 1 回計算するごとに呼ぶ（Wait(0) を挟んで少しずつ進めるため）
function E.warmup(want, step)
    local stopped = {}
    for reel = 1, 3 do
        for press = 0, N - 1 do
            E.decide(want, stopped, reel, press)
            if step then step() end
        end
    end
end

-- 押し順どおりに止める位置を出す。presses は { { reel=1, press=5 }, ... }（押した順）
-- 戻り値: 止まった位置 { [1]=p, [2]=p, [3]=p }、不正なら nil
function E.resolve(want, presses)
    if type(presses) ~= 'table' or #presses ~= 3 then return nil end
    local stopped, seen = {}, {}
    for i = 1, 3 do
        local pr = presses[i]
        local reel = type(pr) == 'table' and tonumber(pr.reel)
        local press = type(pr) == 'table' and tonumber(pr.press)
        if not reel or not press or reel < 1 or reel > 3 or seen[reel] then return nil end
        if press < 0 or press >= N or press ~= math.floor(press) then return nil end
        seen[reel] = true
        stopped[reel] = E.decide(want, stopped, reel, press)
    end
    return stopped
end

-- 払い出し枚数と揃った役。bonusMode が true ならベルは BonusBellPay 枚
function E.payout(want, pos, bonusMode)
    local pay, got = 0, nil
    for _, h in ipairs(E.evaluate(pos)) do
        if h.combo == want then
            got = want
            if want == 'bell' and bonusMode then
                pay = pay + E.BonusBellPay
            else
                pay = pay + E.Combos[want].pay
            end
        end
    end
    if pay > E.MaxPay then pay = E.MaxPay end
    return pay, got
end

-- 管理者の「確実に当たり」用: want が必ず揃う止まり方（3 リールの位置）を探す
local forced = {}
function E.findStops(want)
    if forced[want] then return forced[want] end
    for a = 0, N - 1 do
        for b = 0, N - 1 do
            for c = 0, N - 1 do
                local pos = E.resolve(want, { { reel = 1, press = a }, { reel = 2, press = b }, { reel = 3, press = c } })
                local _, got = E.payout(want, pos, false)
                if got == want then
                    forced[want] = pos
                    return pos
                end
            end
        end
    end
end

return E
