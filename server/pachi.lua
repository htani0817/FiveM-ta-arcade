-- ta-arcade のパチンコ「宵花火」: 打ち出し、持ち玉とお金、管理者の「確実に当たり」
-- 玉の動きは server/pachi_physics.lua、図柄の抽選と状態は server/pachi_engine.lua
-- クライアントから受け取るのは「台の番号」「打つかどうか」「ハンドルの強さ」だけ
local A = Arcade
local E = PachiEngine
local C = Config.Pachi

-- 玉を動かすのは物理計算。打ち出しのむらの乱数もサーバーで引く
E.simulate = function(power, gates)
    return PachiPhysics.simulate(power, E.random, gates)
end

local sessions = {} -- [src] = { id, src, citizenid, balls, force, nextShot, nextSync }

-- 通信の揺れで少し早く届いた分は許す（ミリ秒）
local JITTER = 150
-- 打っていないときの問い合わせ（変動の続きを受け取る）の最短の間隔
local SYNC_INTERVAL = 300

---------------------------------------------------------------------------
-- 台の情報
---------------------------------------------------------------------------

local function emptyData()
    return { total = 0, kakuhen = 0, normal = 0, since = 0, history = {} }
end

-- 持ち玉の控え（owner）は見せない
local function publicData(m)
    local d = m.data
    return { total = d.total or 0, kakuhen = d.kakuhen or 0, normal = d.normal or 0, since = d.since or 0, history = d.history or {} }
end

local function stateInfo(m, now)
    return E.view(m.state, now, C)
end

local function seatInfo(m, s, now)
    local info = stateInfo(m, now)
    info.id = m.id
    info.balls = s.balls
    info.inflight = E.inflight(m.state) -- 飛んでいる玉の賞球（届いたら持ち玉に入る）
    info.cash = exports.qbx_core:GetMoney(s.src, 'cash') or 0
    info.data = publicData(m)
    -- 管理者には中の状態も見せる（台の横の管理パネル用）
    if A.isAdmin(s.src) then
        info.admin = { setting = m.setting, force = s.force }
    end
    return info
end

-- ランプが変わったときだけ全員に配る（1発ごとには配らない）
local function syncLamp(m)
    local lamp = E.lamp(m.state)
    if lamp ~= m.state.lampSent then
        m.state.lampSent = lamp
        A.broadcastState(m)
    end
end

-- 持ち玉と持ち主を台のデータに控える。60秒ごとに DB へ書かれ、サーバーが落ちても次の起動で持ち主に返せる
local function keepOwner(m, s)
    m.data.owner = { cid = s.citizenid, balls = s.balls + E.inflight(m.state) }
    A.markDirty(m)
end

A.registerGame('pachi', {
    emptyData = emptyData,
    init = function(m)
        -- 壊れたデータや古い形のデータは、足りない所を初期値で埋める
        local base = emptyData()
        for k, v in pairs(base) do
            if type(m.data[k]) ~= type(v) then m.data[k] = v end
        end
        -- 前回サーバーが落ちたときに打っていた人の持ち玉を返す
        local owner = m.data.owner
        if type(owner) == 'table' and owner.cid and (tonumber(owner.balls) or 0) > 0 then
            A.pay(owner.cid, math.floor(owner.balls) * C.BallPrice, 'ta-arcade パチンコ 精算（サーバー停止）')
        end
        if owner ~= nil then
            m.data.owner = nil
            A.saveMachine(m)
        end
        m.state = E.newState()
        m.state.lampSent = false
    end,
    lamp = function(m) return E.lamp(m.state) end,
    publicData = publicData,
    adminState = function(m) return stateInfo(m, A.now()) end,
    onDrop = function(src) A.pachiLeave(src, true) end,
    onStop = function() for src in pairs(sessions) do A.pachiLeave(src, true) end end,
})

---------------------------------------------------------------------------
-- 座る・立つ
---------------------------------------------------------------------------

function A.pachiLeave(src, dropped)
    local s = sessions[src]
    if not s then return 0 end
    sessions[src] = nil
    local m = A.machines[s.id]
    if m then
        -- 飛んでいる玉の賞球は、届くのを待たずに受け取る（玉は盤面に残り、届けば保留にはなる）
        s.balls = s.balls + E.advance(m.state, m.data, A.now(), C, m.setting, nil, nil) + E.settle(m.state)
        m.seat = nil
        -- 持ち玉の控えはすぐ消す（次の起動で二重に返さないため、精算より先に DB へ書く）
        m.data.owner = nil
        A.saveMachine(m)
        A.broadcastState(m)
    end
    return A.pay(s.citizenid, s.balls * C.BallPrice, dropped and 'ta-arcade パチンコ 精算（切断）' or 'ta-arcade パチンコ 精算')
end

local function seated(src, id)
    local s = sessions[src]
    local m = s and A.machines[s.id]
    if not m or m.id ~= tonumber(id) or m.seat ~= src then return nil end
    return s, m
end

-- ここから席を確保するまでの間に、待ち（await）を挟まない（挟むと同時に 2 人が座れる）
lib.callback.register('ta-arcade:pachi:sit', function(src, id)
    id = tonumber(id)
    local m = id and A.machines[id]
    if not m or m.game ~= 'pachi' then return { ok = false, reason = 'この台はもうありません' } end
    if sessions[src] then return { ok = false, reason = 'もう別の台に座っています' } end
    if m.seat and m.seat ~= src then return { ok = false, reason = 'ほかの人が打っています' } end
    local player = exports.qbx_core:GetPlayer(src)
    if not player then return { ok = false, reason = 'キャラクターの情報がありません' } end
    if not A.distanceOk(src, m) then return { ok = false, reason = '台から離れすぎています' } end
    m.seat = src
    local s = { id = id, src = src, citizenid = player.PlayerData.citizenid, balls = 0, nextShot = 0, nextSync = 0 }
    sessions[src] = s
    local now = A.now()
    -- 空いていた間に終わった変動を進めておく（前の人の玉の賞球は、立ったときに渡し終えている）
    E.advance(m.state, m.data, now, C, m.setting, nil, nil)
    syncLamp(m)
    A.broadcastState(m)
    A.retryUnpaidLater(s.citizenid)
    return { ok = true, info = seatInfo(m, s, now) }
end)

lib.callback.register('ta-arcade:pachi:leave', function(src)
    return { ok = true, yen = A.pachiLeave(src, false) }
end)

---------------------------------------------------------------------------
-- 打つ
---------------------------------------------------------------------------

-- 前回から interval たっていれば true。少し早いだけなら許すが、その分は次の時刻に積むので、平均では速くならない
local function allow(s, key, now, interval)
    local nextAt = s[key] or 0
    if now < nextAt - JITTER then return false end
    s[key] = math.max(now, nextAt) + interval
    return true
end

-- fire が true なら玉を 1 個打つ。false なら続き（玉の到着・変動）だけを受け取る。power はハンドルの強さ 0〜100
local function tick(src, id, fire, power)
    local s, m = seated(src, id)
    -- サーバー側で席が無くなっている（精算済み・台の撤去など）。left を返して、画面も閉じさせる
    if not m then return { ok = false, left = true, reason = '台に座っていません' } end
    if not A.distanceOk(src, m) then
        local yen = A.pachiLeave(src, false)
        return { ok = false, left = true, yen = yen, reason = '台から離れたので精算しました' }
    end
    local st = m.state
    local now = A.now()
    local events = {}
    local force = s.force and A.isAdmin(src) and s.force or nil
    -- この間に届いた玉の賞球を持ち玉に入れる
    s.balls = s.balls + E.advance(st, m.data, now, C, m.setting, force, events)

    local res = { ok = true, events = events }
    if fire then
        if not allow(s, 'nextShot', now, C.ShotInterval) then
            res.wait = true
        else
            -- 持ち玉が無ければ現金から借りる。玉を渡すのは引き落とせた後だけ
            local stop = nil
            if s.balls < 1 then
                local yen = C.LendUnit * C.BallPrice
                local cash = exports.qbx_core:GetMoney(src, 'cash') or 0
                if cash < yen or not exports.qbx_core:RemoveMoney(src, 'cash', yen, 'ta-arcade パチンコ 玉貸し') then
                    stop = ('現金が足りません（%d玉で %d円いります）'):format(C.LendUnit, yen)
                else
                    s.balls = s.balls + C.LendUnit
                    res.lent = yen
                end
            end
            if stop then
                res.stop = stop
            else
                s.balls = s.balls - 1
                -- ハンドルの強さは 0〜100 の整数に直す（それ以外の値は受け取らない）
                power = math.floor(tonumber(power) or 0)
                if power < 0 then power = 0 elseif power > 100 then power = 100 end
                local r, pay = E.shoot(st, now, C, power)
                -- 軌道（サーバーが計算した玉の動き）を画面へ渡す。賞球は玉が届いた時刻に入る
                res.shot = { to = r.to, t = r.t, pay = pay, path = r.path, hits = r.hits }
            end
        end
    elseif not allow(s, 'nextSync', now, SYNC_INTERVAL) then
        res.wait = true
    end

    -- 上限を超えた分はその場で現金にする（渡せなければ A.pay が未払いに残す）
    if s.balls > C.MaxBalls then
        res.cashOut = A.pay(s.citizenid, (s.balls - C.MaxBalls) * C.BallPrice, 'ta-arcade パチンコ 払い出し')
        s.balls = C.MaxBalls
    end

    keepOwner(m, s)
    syncLamp(m)
    res.info = seatInfo(m, s, now)
    return res
end

lib.callback.register('ta-arcade:pachi:shoot', function(src, id, power)
    return tick(src, id, true, power)
end)

lib.callback.register('ta-arcade:pachi:sync', function(src, id)
    return tick(src, id, false, nil)
end)

---------------------------------------------------------------------------
-- 打っている管理者だけ: 確実に当たり、設定
---------------------------------------------------------------------------

lib.callback.register('ta-arcade:pachi:adminForce', function(src, mode)
    if not A.adminOnly(src) then return { ok = false } end
    local s = sessions[src]
    local m = s and A.machines[s.id]
    if not m then return { ok = false, reason = '台に座っていません' } end
    s.force = (mode == 'kakuhen' or mode == 'normal') and mode or nil
    return { ok = true, info = seatInfo(m, s, A.now()) }
end)

lib.callback.register('ta-arcade:pachi:adminSetting', function(src, setting)
    if not A.adminOnly(src) then return { ok = false } end
    local s = sessions[src]
    local m = s and A.machines[s.id]
    if not m then return { ok = false, reason = '台に座っていません' } end
    m.setting = A.clampSetting(setting)
    A.saveMachine(m)
    return { ok = true, info = seatInfo(m, s, A.now()) }
end)
