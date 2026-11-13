-- ta-arcade のパチンコ「宵花火」の中身: 飛んでいる玉、保留、図柄の抽選、大当たりのラウンド、時刻で進む状態
-- 玉がどこへ行くかは物理計算（server/pachi_physics.lua）が決める。ここは「届いた玉をどう扱うか」だけを持つ
-- FiveM の関数は使わない（tests/ からそのまま動かす）。サーバーだけが読む
PachiEngine = {}
local E = PachiEngine

-- テストで差し替えられるようにしておく
E.random = math.random
-- 玉を 1 個動かす関数。server/pachi.lua が物理計算をつなぐ。テストでは決まった行き先を返すものに差し替える
--   simulate(power, gates) → { to, t, path, hits }
E.simulate = nil

local HUGE = math.huge

-- 台の中の状態
--   mode      normal / kakuhen（確変）/ jitan（時短）
--   flying    飛んでいる玉。届く時刻の早い順。{ at, to, pay }
--   queue     保留。{ at = 入った時刻, via = 'heso' / 'denchu', r, k = 抽選に使う乱数, hot = 保留の色 }
--   spin      いまの変動。{ startAt, endAt, hit, stage, yokoku, digits, jp }
--   jackpot   大当たり中。{ kind, rounds, wins = { { open, close, arr = 届く時刻の並び } }, endAt }
--   freeAt    次の変動を始めてよい時刻
function E.newState()
    return { mode = 'normal', jitanLeft = 0, flying = {}, queue = {}, spin = nil, jackpot = nil, freeAt = 0 }
end

-- { 値, 割合 } の並びから 1 つ選ぶ
local function pick(list)
    local r, acc = E.random(), 0.0
    for i = 1, #list do
        acc = acc + list[i][2]
        if r < acc then return list[i][1] end
    end
    return list[#list][1]
end

-- 止まる図柄（1〜9 を 3 つ）。確変当たりは奇数、通常当たりは偶数が揃う
local ODD, EVEN = { 1, 3, 5, 7, 9 }, { 2, 4, 6, 8 }
local function digits(hit, reach)
    local function rnd(n) return math.floor(E.random() * n) + 1 end
    if hit == 'kakuhen' then
        local d = ODD[rnd(#ODD)]
        return { d, d, d }
    elseif hit == 'normal' then
        local d = EVEN[rnd(#EVEN)]
        return { d, d, d }
    end
    local a = rnd(9)
    if reach then
        -- 左と右が同じで、中だけ 1 つずれる
        return { a, a % 9 + 1, a }
    end
    local c = (a + rnd(8) - 1) % 9 + 1 -- 左と違う図柄
    return { a, rnd(9), c }
end

local function push(events, e)
    if events then events[#events + 1] = e end
end

local function hitChance(st, C, setting)
    return 1.0 / (st.mode == 'kakuhen' and C.HighChance or (C.HitChance[setting] or C.HitChance[1]))
end

---------------------------------------------------------------------------
-- 玉が入賞口に届いた
---------------------------------------------------------------------------
local function land(st, b, C, setting)
    if b.to ~= 'heso' and b.to ~= 'denchu' then return end
    -- 保留がいっぱいなら抽選はされない（賞球は出る）
    if #st.queue >= C.HoldMax then return end
    local q = { at = b.at, via = b.to, r = E.random(), k = E.random(), hot = 'white' }
    -- 保留の色（先読み）。入った時点の確率で当たりかどうかを見て、当たりなら色が変わりやすい
    local hot = C.Hot
    local x = E.random()
    if q.r < hitChance(st, C, setting) then
        if x < hot.hitRed then q.hot = 'red' elseif x < hot.hitRed + hot.hitGreen then q.hot = 'green' end
    else
        if x < hot.missRed then q.hot = 'red' elseif x < hot.missRed + hot.missGreen then q.hot = 'green' end
    end
    st.queue[#st.queue + 1] = q
end

---------------------------------------------------------------------------
-- 変動を始める
---------------------------------------------------------------------------
local function startSpin(st, q, t0, C, setting, force, now, events)
    local T = C.Time
    local support = st.mode ~= 'normal'
    local hit = nil
    if force and st.mode == 'normal' then
        hit = force
    elseif q.r < hitChance(st, C, setting) then
        hit = q.k < C.KakuhenRate and 'kakuhen' or 'normal'
    end

    -- 演出の種類（none: ふつうのハズレ、reach: ノーマルリーチ、sp: スーパーリーチ、full: 全回転）と予告の強さ（0〜3）
    local S = C.Stage
    local stage, yokoku = 'none', 0
    local x, y = E.random(), E.random()
    if hit then
        stage = x < S.hitFull and 'full' or (x < S.hitFull + S.hitSp and 'sp' or 'reach')
        yokoku = y < 0.35 and 3 or (y < 0.70 and 2 or (y < 0.90 and 1 or 0))
    elseif x < S.missReach then
        stage = E.random() < S.missSp and 'sp' or 'reach'
        yokoku = y < 0.10 and 2 or (y < 0.40 and 1 or 0)
    else
        yokoku = y < 0.05 and 1 or 0
    end

    local dur
    if stage == 'none' then
        dur = support and T.spinSupport or (#st.queue >= 2 and T.spinShort or T.spin)
    else
        dur = T[stage .. (support and 'Support' or '')]
        if hit then dur = dur + T.hitTail end
    end

    local sp = { startAt = t0, endAt = t0 + dur, hit = hit, stage = stage, yokoku = yokoku, digits = digits(hit, stage ~= 'none') }
    if hit then
        -- 大当たりのラウンドは、変動が始まった時点で予定を組む（変動中に打った玉が、開いた後に届くことがあるため）
        local rounds = pick(C.Rounds[q.via] or C.Rounds.heso)
        sp.jp = { kind = hit, rounds = rounds, wins = { { open = sp.endAt + T.fanfare, arr = {} } } }
    end
    st.spin = sp
    push(events, {
        t = 'spin', elapsed = now - t0, duration = dur, stage = stage, yokoku = yokoku,
        hit = hit ~= nil, digits = sp.digits, hot = q.hot,
    })
end

---------------------------------------------------------------------------
-- now までに起きたことを、時刻の順に進める。戻り値: この間に届いた玉の賞球の合計
--   d       台のデータカウンター（total / kakuhen / normal / since / history）
--   C       Config.Pachi
--   force   管理者の「確実に当たり」（'kakuhen' / 'normal' / nil）。通常時の変動だけに効く
--   events  起きたことを足していく表（nil でもよい）
---------------------------------------------------------------------------
function E.advance(st, d, now, C, setting, force, events)
    local gained = 0
    while true do
        local jp = st.jackpot
        local tBall = st.flying[1] and st.flying[1].at or HUGE
        local tJpEnd = jp and jp.endAt or HUGE
        local tSpinEnd = st.spin and st.spin.endAt or HUGE
        local tStart = HUGE
        if not st.spin and not jp and st.queue[1] then tStart = math.max(st.queue[1].at, st.freeAt) end
        local t = math.min(tBall, tJpEnd, tSpinEnd, tStart)
        if t > now then break end

        if t == tBall then
            local b = table.remove(st.flying, 1)
            gained = gained + b.pay
            land(st, b, C, setting)
        elseif t == tJpEnd then
            -- 最後のラウンドが閉じた。大当たりが終わり、確変か時短に入る
            st.jackpot = nil
            if jp.kind == 'kakuhen' then
                st.mode, st.jitanLeft = 'kakuhen', 0
            else
                st.mode, st.jitanLeft = 'jitan', C.JitanSpins
            end
            st.freeAt = jp.endAt + C.Time.ending
            push(events, { t = 'jackpotEnd', mode = st.mode })
        elseif t == tSpinEnd then
            local sp = st.spin
            st.spin = nil
            st.freeAt = sp.endAt
            d.total = d.total + 1
            d.since = d.since + 1
            if sp.hit then
                st.jackpot = sp.jp
                st.jitanLeft = 0
                d[sp.hit] = (d[sp.hit] or 0) + 1
                table.insert(d.history, 1, { t = sp.hit, g = d.since, r = sp.jp.rounds })
                while #d.history > C.HistorySize do table.remove(d.history) end
                d.since = 0
                push(events, { t = 'jackpot', kind = sp.hit, rounds = sp.jp.rounds })
            elseif st.mode == 'jitan' then
                st.jitanLeft = st.jitanLeft - 1
                if st.jitanLeft <= 0 then
                    st.mode, st.jitanLeft = 'normal', 0
                    push(events, { t = 'jitanEnd' })
                end
            end
        else
            startSpin(st, table.remove(st.queue, 1), t, C, setting, force, now, events)
        end
    end
    return gained
end

---------------------------------------------------------------------------
-- アタッカー。時刻 ta に届く玉が入れるかを決め、入れるなら数える
--   ラウンドは「開いてから RoundCount 個目の玉が届くまで」。閉じる時刻は、数えた玉のうちいちばん遅く届く時刻
--   閉じる前に届く玉は、数を超えていても入る（本物の「オーバー入賞」と同じ）
---------------------------------------------------------------------------
local function attackerGate(st, C, ta)
    local jp = st.jackpot or (st.spin and st.spin.jp)
    if not jp then return false end
    for i = 1, #jp.wins do
        local w = jp.wins[i]
        if ta >= w.open and (not w.close or ta <= w.close) then
            w.arr[#w.arr + 1] = ta
            if not w.close and #w.arr >= C.RoundCount then
                local last = 0
                for j = 1, #w.arr do if w.arr[j] > last then last = w.arr[j] end end
                w.close = last
                if i < jp.rounds then
                    jp.wins[i + 1] = { open = last + C.Time.roundGap, arr = {} }
                else
                    jp.endAt = last
                end
            end
            return true
        end
    end
    return false
end

---------------------------------------------------------------------------
-- 玉を 1 個打つ（先に advance を呼んでおく）。戻り値: 物理計算の結果（to / t / path / hits）、賞球
--   賞球は玉が届いた時刻に advance が返す
---------------------------------------------------------------------------
function E.shoot(st, now, C, power)
    local gates = {
        -- 電チューは、打った時点で確変・時短中なら開いているものとする
        denchu = st.mode ~= 'normal' and not st.jackpot,
        attacker = function(t) return attackerGate(st, C, now + t) end,
    }
    local r = E.simulate(power, gates)
    local pay = C.Pay[r.to] or 0
    local b = { at = now + r.t, to = r.to, pay = pay }
    local f = st.flying
    local i = #f + 1
    while i > 1 and f[i - 1].at > b.at do i = i - 1 end
    table.insert(f, i, b)
    return r, pay
end

-- まだ届いていない玉の賞球の合計
function E.inflight(st)
    local n = 0
    for i = 1, #st.flying do n = n + st.flying[i].pay end
    return n
end

-- 席を立つとき: 飛んでいる玉の賞球を先に受け取る（玉は盤面に残り、届けば保留にはなる）
function E.settle(st)
    local n = E.inflight(st)
    for i = 1, #st.flying do st.flying[i].pay = 0 end
    return n
end

-- ランプ（大当たり中・確変中・時短中）
function E.lamp(st)
    return st.jackpot ~= nil or st.mode ~= 'normal'
end

-- 画面に見せる形
function E.view(st, now, C)
    local sp, jp = st.spin, st.jackpot
    local holds = {}
    for i = 1, #st.queue do holds[i] = st.queue[i].hot end
    local v = {
        mode = st.mode, jitanLeft = st.jitanLeft, hold = #st.queue, holds = holds, flying = #st.flying,
        nextLand = st.flying[1] and (st.flying[1].at - now) or nil,
    }
    if sp then
        v.spin = { elapsed = now - sp.startAt, duration = sp.endAt - sp.startAt, stage = sp.stage, yokoku = sp.yokoku, hit = sp.hit ~= nil, digits = sp.digits }
    end
    if jp then
        local round, w = 1, jp.wins[1]
        for i = 1, #jp.wins do
            if jp.wins[i].open <= now then round, w = i, jp.wins[i] end
        end
        local count = 0
        for j = 1, #w.arr do if w.arr[j] <= now then count = count + 1 end end
        v.jackpot = {
            kind = jp.kind, round = round, rounds = jp.rounds, count = count,
            open = now >= w.open and (not w.close or now <= w.close),
        }
    end
    return v
end
