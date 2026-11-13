-- ta-arcade のパチンコ「宵花火」クライアント: 座る、打ち出しの間だけサーバーに問い合わせる、台の画面（NUI）とのやり取り
-- 玉の行き先も当たり外れもサーバーが決める。ここは「打つ / 打たない」を伝え、返事を画面へ渡すだけ
local AC = ArcadeClient
local C = Config.Pachi

local seated = nil -- 座っている台 { id, firing, power, syncAt }
local sit, showData

AC.registerGame('pachi', {
    lampLight = C.LampLight,
    targetOptions = function(id)
        return {
            {
                name = 'ta_arcade_pachi_play', icon = 'fa-solid fa-circle-dot', label = 'パチンコを打つ', distance = 2.0,
                canInteract = function() return not AC.busy and AC.machines[id] and not AC.machines[id].busy end,
                onSelect = function() sit(id) end,
            },
            {
                name = 'ta_arcade_pachi_data', icon = 'fa-solid fa-chart-column', label = 'データを見る', distance = 2.5,
                canInteract = function() return not AC.busy end,
                onSelect = function() showData(id) end,
            },
        }
    end,
    forceClose = function() if AC.pachiForceClose then AC.pachiForceClose() end end,
})

---------------------------------------------------------------------------
-- 座る・立つ
---------------------------------------------------------------------------

-- 画面を閉じて立つ。どの経路（精算・失敗・死亡・切り替え・停止）でも、NUI のフォーカスはここで必ず外す
local function standUp()
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'pachi:close' })
    local ped = cache.ped
    ClearPedTasks(ped)
    local m = seated and AC.machines[seated.id]
    if m and m.obj then
        -- 椅子の後ろに降ろす
        local p = GetOffsetFromEntityInWorldCoords(m.obj, 0.0, -1.25, 0.0)
        SetEntityCoords(ped, p.x, p.y, p.z, false, false, false, false)
        SetEntityHeading(ped, m.heading)
    end
    seated = nil
    AC.busy = false
end

local function leaveSeat(silent)
    if not seated then return end
    local res = lib.callback.await('ta-arcade:pachi:leave', false)
    standUp()
    if silent then return end
    if not res then
        AC.notify('サーバーから返事がありません。持ち玉はサーバーに残っていて、あとで精算されます', 'error')
    elseif res.yen and res.yen > 0 then
        AC.notify(('精算しました（%s を受け取りました）'):format(AC.yen(res.yen)), 'success')
    end
end

-- キャラクターの切り替え: サーバーが精算済みなので、画面を閉じて立つだけ
AC.pachiForceClose = function()
    if seated then standUp() end
end

-- 打っていない間に、次にサーバーへ問い合わせる時刻を決める（要らなければ nil）
--   飛んでいる玉も変動も無いときは問い合わせない
local function planSync(s, info)
    local wait = nil
    -- 飛んでいる玉がある: いちばん早く届く時刻に（賞球と保留を受け取る）
    if info.flying > 0 and info.nextLand then wait = math.max(C.ShotInterval // 2, info.nextLand + 50) end
    -- 変動中: 変動が終わる時刻に
    if info.spin then
        local left = math.max(0, info.spin.duration - info.spin.elapsed) + 50
        if not wait or left < wait then wait = left end
    end
    s.syncAt = wait and (GetGameTimer() + wait) or nil
end

-- サーバーの返事を画面へ渡す。戻り値が false なら席を立った
local function handle(s, res)
    if not res then
        -- 時間切れ。打ち出しを止めて知らせる（持ち玉はサーバーが持っている）
        if s.firing then
            s.firing = false
            SendNUIMessage({ action = 'pachi:fire', on = false })
            AC.notify('サーバーから返事がありません。打ち出しを止めました', 'error')
        end
        return true
    end
    if not res.ok then
        if res.left then
            standUp()
            AC.notify(res.reason or '精算しました', 'info')
            if res.yen and res.yen > 0 then AC.notify(('%s を受け取りました'):format(AC.yen(res.yen)), 'success') end
            return false
        end
        s.firing = false
        s.syncAt = nil -- 同じ失敗を繰り返し問い合わせない
        SendNUIMessage({ action = 'pachi:fire', on = false })
        AC.notify(res.reason or '打てませんでした', 'error')
        return true
    end
    if res.stop then
        s.firing = false
        AC.notify(res.stop, 'error')
    end
    if res.cashOut and res.cashOut > 0 then
        AC.notify(('持ち玉がいっぱいなので %s を現金で受け取りました'):format(AC.yen(res.cashOut)), 'success', 3000)
    end
    local info = res.info
    planSync(s, info)
    SendNUIMessage({ action = 'pachi:tick', shot = res.shot, events = res.events, info = info, lent = res.lent, firing = s.firing })
    return true
end

sit = function(id)
    local m = AC.machines[id]
    if not m or not m.obj or AC.busy then return end
    local res = lib.callback.await('ta-arcade:pachi:sit', false, id)
    if not res or not res.ok then
        AC.notify(res and res.reason or '座れませんでした', 'error')
        return
    end
    AC.busy = true
    local s = { id = id, firing = false, power = 0, syncAt = nil }
    seated = s
    planSync(s, res.info)
    local o = C.SitOffset
    local p = GetOffsetFromEntityInWorldCoords(m.obj, o.x, o.y, o.z)
    TaskStartScenarioAtPosition(cache.ped, C.SitScenario, p.x, p.y, p.z, m.heading, 0, true, true)

    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'pachi:open',
        info = res.info,
        price = C.BallPrice,
        lend = C.LendUnit,
        maxBalls = C.MaxBalls,
        interval = C.ShotInterval,
        board = PachiBoard.export(), -- 釘・風車・入賞口の並び（サーバーの物理計算と同じもの）
        pay = C.Pay,
        roundCount = C.RoundCount,
        jitan = C.JitanSpins,
        scale = Config.UiScale,
    })

    -- 打っている間と、変動の続きがある間だけ、打ち出しの間隔でサーバーに問い合わせる
    CreateThread(function()
        local nextAt = GetGameTimer()
        while seated == s do
            local now = GetGameTimer()
            if now >= nextAt then
                nextAt = math.max(nextAt + C.ShotInterval, now + C.ShotInterval // 2)
                if s.firing then
                    if not handle(s, lib.callback.await('ta-arcade:pachi:shoot', false, id, s.power)) then break end
                elseif s.syncAt and now >= s.syncAt then
                    if not handle(s, lib.callback.await('ta-arcade:pachi:sync', false, id)) then break end
                end
            end
            Wait(math.max(0, math.min(nextAt - GetGameTimer(), 100)))
        end
    end)

    -- 倒れたり車に乗せられたりしたら席を立つ
    CreateThread(function()
        while seated == s do
            if IsEntityDead(cache.ped) or IsPedRagdoll(cache.ped) or IsPedInAnyVehicle(cache.ped, false) then
                leaveSeat(false)
                break
            end
            Wait(500)
        end
    end)
end

showData = function(id)
    local res = lib.callback.await('ta-arcade:data', false, id)
    if not res then return end
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'pachi:data', id = id, data = res.data })
end

---------------------------------------------------------------------------
-- 画面からの操作
---------------------------------------------------------------------------

RegisterNUICallback('pachi:fire', function(data, cb)
    if not seated then return cb({ ok = false }) end
    seated.firing = data.on == true
    if tonumber(data.power) then seated.power = tonumber(data.power) end
    cb({ ok = true, on = seated.firing })
end)

-- ハンドルを回した（強さ 0〜100）。サーバーでも範囲を確かめる
RegisterNUICallback('pachi:power', function(data, cb)
    if seated and tonumber(data.power) then seated.power = tonumber(data.power) end
    cb({ ok = true })
end)

RegisterNUICallback('pachi:leave', function(_, cb)
    cb({ ok = true })
    leaveSeat(false)
end)

RegisterNUICallback('pachi:closeData', function(_, cb)
    cb({ ok = true })
    if not seated then SetNuiFocus(false, false) end
end)

-- 打っている管理者だけ（台の横の管理パネル）
RegisterNUICallback('pachiAdmin:force', function(data, cb)
    cb(lib.callback.await('ta-arcade:pachi:adminForce', false, data.mode) or { ok = false })
end)

RegisterNUICallback('pachiAdmin:setting', function(data, cb)
    cb(lib.callback.await('ta-arcade:pachi:adminSetting', false, data.setting) or { ok = false })
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if seated then
        SetNuiFocus(false, false)
        ClearPedTasks(cache.ped)
    end
end)
