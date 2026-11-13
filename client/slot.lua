-- ta-arcade のパチスロ「夜祭」クライアント: 座る、台の画面（NUI）とのやり取り、データを見る
local AC = ArcadeClient
local E = SlotEngine
local C = Config.Slot

local seated = nil -- 座っている台 { id, want, stops, stopped, presses }
local sit, showData

AC.registerGame('slot', {
    lampLight = C.LampLight,
    targetOptions = function(id)
        return {
            {
                name = 'ta_arcade_slot_play', icon = 'fa-solid fa-coins', label = 'スロットを打つ', distance = 2.0,
                canInteract = function() return not AC.busy and AC.machines[id] and not AC.machines[id].busy end,
                onSelect = function() sit(id) end,
            },
            {
                name = 'ta_arcade_slot_data', icon = 'fa-solid fa-chart-column', label = 'データを見る', distance = 2.5,
                canInteract = function() return not AC.busy end,
                onSelect = function() showData(id) end,
            },
        }
    end,
    warmup = function(step)
        for _, want in ipairs({ false, 'replay', 'bell', 'suika', 'cherry', 'big', 'reg' }) do
            E.warmup(want or nil, step)
        end
    end,
    forceClose = function() if AC.slotForceClose then AC.slotForceClose() end end,
})

---------------------------------------------------------------------------
-- 座る・立つ
---------------------------------------------------------------------------

local function standUp()
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
    local res = lib.callback.await('ta-arcade:slot:leave', false)
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
    standUp()
    if not silent and res and res.yen and res.yen > 0 then
        AC.notify(('精算しました（%s を受け取りました）'):format(AC.yen(res.yen)), 'success')
    end
end

-- キャラクターの切り替え: サーバーが精算済みなので、画面を閉じて立つだけ
AC.slotForceClose = function()
    if not seated then return end
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
    standUp()
end

sit = function(id)
    local m = AC.machines[id]
    if not m or not m.obj or AC.busy then return end
    local res = lib.callback.await('ta-arcade:slot:sit', false, id)
    if not res or not res.ok then
        AC.notify(res and res.reason or '座れませんでした', 'error')
        return
    end
    AC.busy = true
    seated = { id = id, want = nil, stops = nil, stopped = {}, presses = {} }
    local o = C.SitOffset
    local p = GetOffsetFromEntityInWorldCoords(m.obj, o.x, o.y, o.z)
    TaskStartScenarioAtPosition(cache.ped, C.SitScenario, p.x, p.y, p.z, m.heading, 0, true, true)

    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'open',
        info = res.info,
        reels = E.Reels,
        price = C.MedalPrice,
        bet = C.Bet,
        maxCredit = C.MaxCredit,
        wait = C.GameWait,
        bonus = { big = C.Bonus.big.endPay, reg = C.Bonus.reg.endPay },
        scale = Config.UiScale,
    })

    -- 倒れたり車に乗せられたりしたら席を立つ
    CreateThread(function()
        while seated and seated.id == id do
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
    SendNUIMessage({ action = 'data', id = id, data = res.data })
end

---------------------------------------------------------------------------
-- 画面からの操作
---------------------------------------------------------------------------

RegisterNUICallback('lever', function(_, cb)
    if not seated then return cb({ ok = false }) end
    local res = lib.callback.await('ta-arcade:slot:lever', false, seated.id)
    if res and res.ok then
        seated.want = res.want
        seated.stops = res.stops
        seated.stopped = {}
        seated.presses = {}
        res.want, res.stops = nil, nil -- 画面には渡さない
    end
    cb(res or { ok = false })
end)

-- 押した位置から止まる位置を決める（サーバーも同じ計算で答え合わせをする）
RegisterNUICallback('press', function(data, cb)
    if not seated then return cb({ ok = false }) end
    local reel, press = tonumber(data.reel), tonumber(data.press)
    if not reel or not press or seated.stopped[reel] then return cb({ ok = false }) end
    press = math.floor(press) % E.Size
    local stop
    if seated.stops then
        stop = seated.stops[reel] -- 管理者の「確実に当たり」: 揃う位置まで回してから止める
    else
        stop = E.decide(seated.want, seated.stopped, reel, press)
    end
    seated.stopped[reel] = stop
    seated.presses[#seated.presses + 1] = { reel = reel, press = press }
    cb({ ok = true, stop = stop })
end)

RegisterNUICallback('result', function(_, cb)
    if not seated or #seated.presses ~= 3 then return cb({ ok = false }) end
    local res = lib.callback.await('ta-arcade:slot:stop', false, seated.id, seated.presses)
    if res and res.cashOut and res.cashOut > 0 then
        AC.notify(('クレジットがいっぱいなので %s を現金で受け取りました'):format(AC.yen(res.cashOut)), 'success', 3000)
    end
    cb(res or { ok = false })
end)

RegisterNUICallback('leave', function(_, cb)
    cb({ ok = true })
    leaveSeat(false)
end)

RegisterNUICallback('closeData', function(_, cb)
    cb({ ok = true })
    if not seated then SetNuiFocus(false, false) end
end)

-- 打っている管理者だけ（台の横の管理パネル）
RegisterNUICallback('slotAdmin:force', function(data, cb)
    cb(lib.callback.await('ta-arcade:slot:adminForce', false, data.mode) or { ok = false })
end)

RegisterNUICallback('slotAdmin:setting', function(data, cb)
    cb(lib.callback.await('ta-arcade:slot:adminSetting', false, data.setting) or { ok = false })
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if seated then
        SetNuiFocus(false, false)
        ClearPedTasks(cache.ped)
    end
end)
