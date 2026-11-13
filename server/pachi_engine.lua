-- ta-arcade のパチンコ「宵花火」の中身: 玉の行き先、図柄の抽選、保留、時刻で進む状態
-- FiveM の関数は使わない（tests/ からそのまま動かす）。サーバーだけが読む
PachiEngine = {}
local E = PachiEngine

-- テストで差し替えられるようにしておく
E.random = math.random

-- 台の中の状態
--   mode      normal / kakuhen（確変）/ jitan（時短）
--   queue     保留。{ at = 入賞口に届く時刻, via = 'heso' / 'denchu' }
--   spin      いまの変動。{ startAt, endAt, hit, rounds, reach, digits }
--   jackpot   大当たり中。{ kind, rounds, round, count, openAt }
--   freeAt    次の変動を始めてよい時刻
function E.newState()
    return { mode = 'normal', jitanLeft = 0, queue = {}, spin = nil, jackpot = nil, freeAt = 0 }
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

-- now までに終わった変動を確定し、保留があれば次の変動を始める
--   d       台のデータカウンター（total / kakuhen / normal / since / history）
--   C       Config.Pachi
--   force   管理者の「確実に当たり」（'kakuhen' / 'normal' / nil）。通常時の変動だけに効く
--   events  起きたことを足していく表（nil でもよい）
function E.advance(st, d, now, C, setting, force, events)
    local T = C.Time
    while not st.jackpot do
        local sp = st.spin
        if sp then
            if now < sp.endAt then break end
            st.spin = nil
            st.freeAt = sp.endAt
            d.total = d.total + 1
            d.since = d.since + 1
            if sp.hit then
                st.jackpot = { kind = sp.hit, rounds = sp.rounds, round = 1, count = 0, openAt = sp.endAt + T.fanfare }
                st.jitanLeft = 0
                d[sp.hit] = (d[sp.hit] or 0) + 1
                table.insert(d.history, 1, { t = sp.hit, g = d.since, r = sp.rounds })
                while #d.history > C.HistorySize do table.remove(d.history) end
                d.since = 0
                push(events, { t = 'jackpot', kind = sp.hit, rounds = sp.rounds })
            elseif st.mode == 'jitan' then
                st.jitanLeft = st.jitanLeft - 1
                if st.jitanLeft <= 0 then
                    st.mode, st.jitanLeft = 'normal', 0
                    push(events, { t = 'jitanEnd' })
                end
            end
        else
            local q = st.queue[1]
            if not q then break end
            local t0 = math.max(q.at, st.freeAt)
            if t0 > now then break end
            table.remove(st.queue, 1)

            local support = st.mode ~= 'normal'
            local hit = nil
            if force and st.mode == 'normal' then
                hit = force
            else
                local n = st.mode == 'kakuhen' and C.HighChance or (C.HitChance[setting] or C.HitChance[1])
                if E.random() < 1.0 / n then
                    hit = E.random() < C.KakuhenRate and 'kakuhen' or 'normal'
                end
            end
            local dur, reach = nil, false
            if hit then
                dur, reach = support and T.hitSupport or T.hit, true
            elseif E.random() < T.reachChance then
                dur, reach = support and T.reachSupport or T.reach, true
            elseif support then
                dur = T.spinSupport
            else
                dur = #st.queue >= 2 and T.spinShort or T.spin
            end
            st.spin = {
                startAt = t0, endAt = t0 + dur, hit = hit, reach = reach,
                rounds = hit and pick(C.Rounds[q.via] or C.Rounds.heso) or nil,
                digits = digits(hit, reach),
            }
            push(events, { t = 'spin', elapsed = now - t0, duration = dur, reach = reach, hit = hit ~= nil, digits = st.spin.digits })
        end
    end
end

-- 玉を 1 個打つ（先に advance を呼んでおく）。戻り値: 行き先（miss / heso / denchu / attacker）、賞球
function E.shoot(st, now, C, events)
    local jp = st.jackpot
    if jp then
        -- 大当たり中は右打ち。アタッカーが開いていれば入る
        if now < jp.openAt or E.random() >= C.Entry.attacker then return 'miss', 0 end
        jp.count = jp.count + 1
        if jp.count >= C.RoundCount then
            if jp.round >= jp.rounds then
                st.jackpot = nil
                if jp.kind == 'kakuhen' then
                    st.mode, st.jitanLeft = 'kakuhen', 0
                else
                    st.mode, st.jitanLeft = 'jitan', C.JitanSpins
                end
                st.freeAt = now + C.Time.ending
                push(events, { t = 'jackpotEnd', mode = st.mode })
            else
                jp.round, jp.count = jp.round + 1, 0
                jp.openAt = now + C.Time.roundGap
            end
        end
        return 'attacker', C.Pay.attacker
    end

    local via = st.mode == 'normal' and 'heso' or 'denchu'
    if E.random() >= C.Entry[via] then return 'miss', 0 end
    -- 保留がいっぱいでも賞球は出る（抽選はされない）
    if #st.queue < C.HoldMax then
        st.queue[#st.queue + 1] = { at = now + C.FallTime, via = via }
    end
    return via, C.Pay[via]
end

-- ランプ（大当たり中・確変中・時短中）
function E.lamp(st)
    return st.jackpot ~= nil or st.mode ~= 'normal'
end
