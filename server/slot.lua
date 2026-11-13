-- ta-arcade のパチスロ「夜祭」: 内部抽選、払い出し、お金の出し入れ、管理者の「確実に当たり」
local A = Arcade
local E = SlotEngine
local C = Config.Slot

local sessions = {} -- [src] = { id, src, credit, citizenid, force }

---------------------------------------------------------------------------
-- 台の情報
---------------------------------------------------------------------------

local function publicData(m)
    local d = m.data
    return { total = d.total or 0, big = d.big or 0, reg = d.reg or 0, since = d.since or 0, history = d.history or {} }
end

local function seatInfo(m, s)
    local st = m.state
    local info = {
        id = m.id,
        credit = s.credit,
        mode = st.mode,
        bonusPay = st.bonusPay,
        endPay = st.mode ~= 'normal' and C.Bonus[st.mode].endPay or 0,
        lamp = st.lamp,
        replay = st.replay,
        data = publicData(m),
        cash = exports.qbx_core:GetMoney(s.src, 'cash') or 0,
    }
    -- 管理者には中の状態も見せる（台の横の管理パネル用）
    if A.isAdmin(s.src) then
        info.admin = { setting = m.setting, carried = st.carried, force = s.force }
    end
    return info
end

A.registerGame('slot', {
    emptyData = function() return { total = 0, big = 0, reg = 0, since = 0, history = {} } end,
    init = function(m)
        m.state = {
            mode = 'normal', -- normal / big / reg
            bonusPay = 0,    -- ボーナス中に払い出した枚数
            carried = nil,   -- 持ち越しているボーナス（big / reg）
            lamp = false,    -- 告知ランプ
            replay = false,  -- 次のゲームはリプレイ（掛け金なし）
            game = nil,      -- レバーを叩いてから止めるまでの情報
            lastLever = 0,
        }
    end,
    lamp = function(m) return m.state.lamp end,
    publicData = publicData,
    adminState = function(m)
        local st = m.state
        return { mode = st.mode, carried = st.carried, bonusPay = st.bonusPay, lamp = st.lamp }
    end,
    onDrop = function(src) A.slotLeave(src, true) end,
    onStop = function() for src in pairs(sessions) do A.slotLeave(src, true) end end,
    warmup = function(step)
        for _, want in ipairs({ false, 'replay', 'bell', 'suika', 'cherry', 'big', 'reg' }) do
            E.warmup(want or nil, step)
        end
    end,
})

---------------------------------------------------------------------------
-- お金
---------------------------------------------------------------------------

local function payCash(s, medals, reason)
    if medals <= 0 then return 0 end
    -- 渡せなかった分は A.pay が未払いとして残し、あとで払い直す
    return A.pay(s.citizenid, medals * C.MedalPrice, reason)
end

---------------------------------------------------------------------------
-- 内部抽選
---------------------------------------------------------------------------

local LOTTERY_ORDER = { 'replay', 'bell', 'suika', 'cherry', 'big', 'reg', 'big_cherry', 'reg_cherry' }

local function draw(setting)
    local t = C.Lottery[setting] or C.Lottery[1]
    local r = math.random()
    local acc = 0.0
    for _, name in ipairs(LOTTERY_ORDER) do
        local d = t[name]
        if d and d > 0 then
            acc = acc + 1.0 / d
            if r < acc then return name end
        end
    end
    return nil
end

-- 1 ゲームの「狙う役」を決める。戻り値: want, 新しく当たったボーナス
local function decideGame(m)
    local st = m.state
    if st.mode ~= 'normal' then
        if math.random() < C.Bonus[st.mode].bellChance then return 'bell', nil end
        return nil, nil
    end
    local flag = draw(m.setting)
    local small, bonus = nil, nil
    if flag == 'big_cherry' then small, bonus = 'cherry', 'big'
    elseif flag == 'reg_cherry' then small, bonus = 'cherry', 'reg'
    elseif flag == 'big' or flag == 'reg' then bonus = flag
    else small = flag end

    -- 持ち越し中はボーナスを重ねて引かない
    local newBonus = nil
    if bonus and not st.carried then
        st.carried = bonus
        newBonus = bonus
    end
    -- 小役が優先。小役が無ければ持ち越しのボーナスを狙う
    return small or st.carried, newBonus
end

---------------------------------------------------------------------------
-- 1 ゲームの終わりと精算
---------------------------------------------------------------------------

local function finishGame(m, s, presses)
    local st = m.state
    local g = st.game
    st.game = nil
    local pos, fixed
    if g.stops then
        -- 管理者の「確実に当たり」: 押した位置にかかわらず揃う位置で止める
        pos = { g.stops[1], g.stops[2], g.stops[3] }
    else
        pos = E.resolve(g.want, presses)
        if not pos then
            -- 不正な押し方は、順押しで全部 0 の位置を押したことにする
            pos = E.resolve(g.want, { { reel = 1, press = 0 }, { reel = 2, press = 0 }, { reel = 3, press = 0 } })
            fixed = true
        end
    end
    local bonusMode = st.mode ~= 'normal'
    local pay, got = E.payout(g.want, pos, bonusMode)
    local started = nil

    if bonusMode then
        st.bonusPay = st.bonusPay + pay
        if st.bonusPay >= C.Bonus[st.mode].endPay then
            st.mode = 'normal'
            st.bonusPay = 0
        end
    else
        local d = m.data
        d.total = d.total + 1
        d.since = d.since + 1
        if got == 'big' or got == 'reg' then
            started = got
            st.mode = got
            st.bonusPay = 0
            st.carried = nil
            st.lamp = false
            d[got] = d[got] + 1
            table.insert(d.history, 1, { t = got, g = d.since })
            while #d.history > C.HistorySize do table.remove(d.history) end
            d.since = 0
        elseif g.lamp == 'post' and st.carried then
            st.lamp = true
        end
        st.replay = got == 'replay'
    end
    A.markDirty(m)

    -- 払い出しはクレジットへ。上限を超えた分は現金で受け取る
    s.credit = s.credit + pay
    local cashOut = 0
    if s.credit > C.MaxCredit then
        cashOut = payCash(s, s.credit - C.MaxCredit, 'ta-arcade スロット 払い出し')
        s.credit = C.MaxCredit
    end
    A.broadcastState(m)
    return {
        ok = true, stops = pos, pay = pay, got = got, started = started, fixed = fixed,
        cashOut = cashOut, info = seatInfo(m, s),
    }
end

function A.slotLeave(src, dropped)
    local s = sessions[src]
    if not s then return 0 end
    local m = A.machines[s.id]
    if m then
        -- 止める前に離れたら、順押しで止めたことにする（掛けたメダルの分の払い出しは受け取れる）
        if m.state.game then finishGame(m, s, { { reel = 1, press = 0 }, { reel = 2, press = 0 }, { reel = 3, press = 0 } }) end
        m.seat = nil
        A.markDirty(m)
        A.broadcastState(m)
    end
    local yen = payCash(s, s.credit, dropped and 'ta-arcade スロット 精算（切断）' or 'ta-arcade スロット 精算')
    sessions[src] = nil
    return yen
end

local function seated(src, id)
    local s = sessions[src]
    local m = s and A.machines[s.id]
    if not m or m.id ~= tonumber(id) or m.seat ~= src then return nil end
    return s, m
end

---------------------------------------------------------------------------
-- 遊ぶ
---------------------------------------------------------------------------

lib.callback.register('ta-arcade:slot:sit', function(src, id)
    id = tonumber(id)
    local m = A.machines[id]
    if not m or m.game ~= 'slot' then return { ok = false, reason = 'この台はもうありません' } end
    if sessions[src] then return { ok = false, reason = 'もう別の台に座っています' } end
    if m.seat and m.seat ~= src then return { ok = false, reason = 'ほかの人が打っています' } end
    local player = exports.qbx_core:GetPlayer(src)
    if not player then return { ok = false, reason = 'キャラクターの情報がありません' } end
    if not A.distanceOk(src, m) then return { ok = false, reason = '台から離れすぎています' } end
    m.seat = src
    sessions[src] = { id = id, credit = 0, src = src, citizenid = player.PlayerData.citizenid }
    A.broadcastState(m)
    A.retryUnpaidLater(player.PlayerData.citizenid)
    return { ok = true, info = seatInfo(m, sessions[src]) }
end)

lib.callback.register('ta-arcade:slot:lever', function(src, id)
    local s, m = seated(src, id)
    if not m then return { ok = false, reason = '台に座っていません' } end
    local st = m.state
    if st.game then return { ok = false, reason = 'リールが回っています' } end
    local wait = C.GameWait - 150 - (A.now() - st.lastLever) -- 通信の揺れの分だけ少し甘くする
    if wait > 0 then return { ok = false, reason = 'wait', wait = wait } end

    -- 掛け金。リプレイの次はいらない。クレジットが足りなければ足りない分を現金から
    local paidYen = 0
    if st.mode == 'normal' and st.replay then
        st.replay = false
    else
        local need = C.Bet - math.min(s.credit, C.Bet)
        if need > 0 then
            local yen = need * C.MedalPrice
            local cash = exports.qbx_core:GetMoney(src, 'cash') or 0
            if cash < yen or not exports.qbx_core:RemoveMoney(src, 'cash', yen, 'ta-arcade スロット 掛け金') then
                return { ok = false, reason = ('現金が足りません（%d円いります）'):format(yen) }
            end
            paidYen = yen
        end
        s.credit = s.credit - (C.Bet - need)
    end

    local want, newBonus, stops = nil, nil, nil
    if s.force and st.mode == 'normal' and A.isAdmin(src) then
        -- 管理者の「確実に当たり」: 抽選せずにボーナスを当て、必ず揃える
        want, newBonus = s.force, s.force
        st.carried = nil
        stops = E.findStops(want)
    else
        want, newBonus = decideGame(m)
    end
    local lamp = nil
    if newBonus then
        lamp = (stops or math.random() < C.LampPreChance) and 'pre' or 'post'
        if lamp == 'pre' then st.lamp = true end
    end
    st.game = { want = want, lamp = lamp, stops = stops }
    st.lastLever = A.now()
    if lamp == 'pre' then A.broadcastState(m) end
    return { ok = true, want = want, stops = stops, paidYen = paidYen, info = seatInfo(m, s) }
end)

lib.callback.register('ta-arcade:slot:stop', function(src, id, presses)
    local s, m = seated(src, id)
    if not m then return { ok = false, reason = '台に座っていません' } end
    if not m.state.game then return { ok = false, reason = 'レバーを叩いていません' } end
    return finishGame(m, s, presses)
end)

lib.callback.register('ta-arcade:slot:leave', function(src)
    return { ok = true, yen = A.slotLeave(src, false) }
end)

---------------------------------------------------------------------------
-- 打っている管理者だけ: 確実に当たり、設定
---------------------------------------------------------------------------

lib.callback.register('ta-arcade:slot:adminForce', function(src, mode)
    if not A.adminOnly(src) then return { ok = false } end
    local s = sessions[src]
    local m = s and A.machines[s.id]
    if not m then return { ok = false, reason = '台に座っていません' } end
    s.force = (mode == 'big' or mode == 'reg') and mode or nil
    return { ok = true, info = seatInfo(m, s) }
end)

lib.callback.register('ta-arcade:slot:adminSetting', function(src, setting)
    if not A.adminOnly(src) then return { ok = false } end
    local s = sessions[src]
    local m = s and A.machines[s.id]
    if not m then return { ok = false, reason = '台に座っていません' } end
    m.setting = A.clampSetting(setting)
    A.saveMachine(m)
    return { ok = true, info = seatInfo(m, s) }
end)
