-- ta-arcade クライアントの共通部分: 台と椅子を置く、ox_target、管理画面（NUI）、設置モード
-- ゲームは ArcadeClient.registerGame(名前, 処理) で登録する（client/slot.lua が見本）
ArcadeClient = {
    machines = {}, -- [id] = { id, game, coords, heading, busy, lamp, obj, chair }
    games = {},
    busy = false,  -- 遊んでいる・設置している間は true
    admin = false,
}
local AC = ArcadeClient

function AC.notify(msg, kind, time)
    exports['okokNotify']:Alert('ゲームセンター', msg, time or 5000, kind or 'info')
end

function AC.yen(n)
    local s = tostring(math.floor(n or 0))
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return (out:gsub('^,', '')) .. '円'
end

-- ゲームの処理に要るもの:
--   targetOptions(id)  台の ox_target に足す選択肢
--   lampLight          ランプの明かり（Config.Slot.LampLight の形。無ければ光らせない）
--   forceClose()       キャラクターの切り替えのとき。座っていたら画面を閉じて立つ（任意）
function AC.registerGame(name, mod) AC.games[name] = mod end

---------------------------------------------------------------------------
-- 台と椅子を置く（近くの台だけ、自分の画面にだけ作る）
---------------------------------------------------------------------------

function AC.chairCoords(obj, game)
    local o = Config.Games[game].chairOffset
    return GetOffsetFromEntityInWorldCoords(obj, o.x, o.y, o.z)
end

local function loadModels(game)
    local g = Config.Games[game]
    if not lib.requestModel(g.model, 10000) then return false end
    if g.chair and not lib.requestModel(g.chair, 10000) then return false end
    return true
end

local openMachineInAdmin -- 前方宣言

local function despawn(m)
    if m.obj and DoesEntityExist(m.obj) then
        exports.ox_target:removeLocalEntity(m.obj)
        DeleteEntity(m.obj)
    end
    if m.chair and DoesEntityExist(m.chair) then DeleteEntity(m.chair) end
    m.obj, m.chair = nil, nil
end

local function spawn(m)
    local g, mod = Config.Games[m.game], AC.games[m.game]
    if not g or not mod then return end
    if not loadModels(m.game) then
        print('[ta-arcade] モデルを読み込めません。stream/ と data_file を確かめてください')
        return
    end
    local obj = CreateObjectNoOffset(g.model, m.coords.x, m.coords.y, m.coords.z, false, false, false)
    SetEntityHeading(obj, m.heading)
    FreezeEntityPosition(obj, true)
    m.obj = obj
    if g.chair then
        local c = AC.chairCoords(obj, m.game)
        local chair = CreateObjectNoOffset(g.chair, c.x, c.y, c.z, false, false, false)
        SetEntityHeading(chair, m.heading)
        FreezeEntityPosition(chair, true)
        m.chair = chair
        SetModelAsNoLongerNeeded(g.chair)
    end
    -- 置いた後はモデルを手放す（置いた物が残っている間はゲームが持ち続ける）
    SetModelAsNoLongerNeeded(g.model)

    local id = m.id
    local options = mod.targetOptions(id)
    options[#options + 1] = {
        name = 'ta_arcade_admin', icon = 'fa-solid fa-screwdriver-wrench', label = '台の管理', distance = 2.5,
        canInteract = function() return not AC.busy and AC.admin end,
        onSelect = function() openMachineInAdmin(id) end,
    }
    exports.ox_target:addLocalEntity(obj, options)
end

local function setMachines(list)
    local keep = {}
    for _, row in ipairs(list or {}) do
        keep[row.id] = true
        local m = AC.machines[row.id]
        local coords = vec3(row.x, row.y, row.z)
        if m and (#(m.coords - coords) > 0.01 or math.abs(m.heading - row.h) > 0.01) then
            despawn(m)
            m = nil
        end
        if not m then
            m = { id = row.id }
            AC.machines[row.id] = m
        end
        m.game, m.coords, m.heading, m.busy, m.lamp = row.game, coords, row.h, row.busy, row.lamp
    end
    for id, m in pairs(AC.machines) do
        if not keep[id] then
            despawn(m)
            AC.machines[id] = nil
        end
    end
end

RegisterNetEvent('ta-arcade:machines', function(list)
    setMachines(list)
end)

RegisterNetEvent('ta-arcade:machineState', function(id, busy, lamp)
    local m = AC.machines[id]
    if m then m.busy, m.lamp = busy, lamp end
end)

CreateThread(function()
    setMachines(lib.callback.await('ta-arcade:list', false))
    AC.admin = lib.callback.await('ta-arcade:isAdmin', false) == true
    for _, mod in pairs(AC.games) do
        if mod.warmup then CreateThread(function() mod.warmup(function() Wait(0) end) end) end
    end
    while true do
        local pos = GetEntityCoords(cache.ped)
        for _, m in pairs(AC.machines) do
            local near = #(pos - m.coords) < Config.SpawnDistance
            if near and not m.obj then
                spawn(m)
            elseif not near and m.obj then
                despawn(m)
            end
        end
        Wait(1000)
    end
end)

-- ランプが光っている台は、周りの人にも明かりが見える
CreateThread(function()
    local lit = {}
    local lastScan = 0
    while true do
        local t = GetGameTimer()
        if t - lastScan > 500 then
            lastScan = t
            lit = {}
            local pos = GetEntityCoords(cache.ped)
            for _, m in pairs(AC.machines) do
                local light = AC.games[m.game] and AC.games[m.game].lampLight
                if light and m.lamp and m.obj and #(pos - m.coords) < 40.0 then
                    local o = light.offset
                    lit[#lit + 1] = { p = GetOffsetFromEntityInWorldCoords(m.obj, o.x, o.y, o.z), l = light }
                end
            end
        end
        if #lit > 0 then
            for i = 1, #lit do
                local p, l = lit[i].p, lit[i].l
                DrawLightWithRange(p.x, p.y, p.z, l.color[1], l.color[2], l.color[3], l.range, l.intensity)
            end
            Wait(0)
        else
            Wait(500)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, m in pairs(AC.machines) do despawn(m) end
end)

---------------------------------------------------------------------------
-- 管理者: 設置モード
---------------------------------------------------------------------------

local adminOpen = false
local openAdmin -- 前方宣言

local function nearestMachine(pos, maxDist, game)
    local best, bestD = nil, maxDist
    for _, m in pairs(AC.machines) do
        local d = #(m.coords - pos)
        if m.game == game and d < bestD then best, bestD = m, d end
    end
    return best
end

local function startPlacement(game, setting)
    if AC.busy or not Config.Games[game] then return end
    if not loadModels(game) then
        AC.notify('モデルを読み込めません', 'error')
        return
    end
    local g = Config.Games[game]
    AC.busy = true
    local ped = cache.ped
    local start = GetEntityCoords(ped)
    local ghost = CreateObjectNoOffset(g.model, start.x, start.y, start.z, false, false, false)
    local ghostChair = g.chair and CreateObjectNoOffset(g.chair, start.x, start.y, start.z, false, false, false) or nil
    for _, e in ipairs({ ghost, ghostChair }) do
        SetEntityAlpha(e, 170, false)
        SetEntityCollision(e, false, false)
        FreezeEntityPosition(e, true)
    end
    local heading = GetEntityHeading(ped)
    local snap = true
    local placed = 0

    lib.showTextUI(table.concat({
        ('%s　設定%d'):format(g.label, setting),
        '[マウス] 置く場所',
        '[ホイール / Q・E] 向き（Shift で細かく）',
        '[G] 隣の台にそろえる: 入/切',
        '[Enter] 置く　[Backspace] 終わる',
    }, '  \n'), { position = 'left-center' })

    CreateThread(function()
        local active = true
        while active do
            for _, c in ipairs({ 24, 25, 44, 38, 14, 15, 16, 17, 140, 141, 142, 47, 200 }) do DisableControlAction(0, c, true) end
            local shift = IsDisabledControlPressed(0, 21)
            local step = shift and 1.0 or 5.0
            if IsDisabledControlJustPressed(0, 14) or IsDisabledControlJustPressed(0, 16) then heading = heading - step end
            if IsDisabledControlJustPressed(0, 15) or IsDisabledControlJustPressed(0, 17) then heading = heading + step end
            if IsDisabledControlPressed(0, 44) then heading = heading + (shift and 0.3 or 1.5) end
            if IsDisabledControlPressed(0, 38) then heading = heading - (shift and 0.3 or 1.5) end
            if IsDisabledControlJustPressed(0, 47) then
                snap = not snap
                AC.notify(snap and '隣の台にそろえます' or 'そろえずに置きます', 'info', 1500)
            end

            local hit, _, coords = lib.raycast.cam(1 | 16, 4, 15.0)
            local pos, h = nil, heading
            if hit then
                pos = coords
                if snap then
                    local n = nearestMachine(coords, g.width * 1.6, game)
                    if n and n.obj then
                        -- 近い台の右か左、置こうとしている側にそろえる
                        local right = GetOffsetFromEntityInWorldCoords(n.obj, g.width, 0.0, 0.0)
                        local left = GetOffsetFromEntityInWorldCoords(n.obj, -g.width, 0.0, 0.0)
                        pos = #(coords - right) < #(coords - left) and right or left
                        h = n.heading
                    end
                end
            end

            if pos then
                SetEntityCoordsNoOffset(ghost, pos.x, pos.y, pos.z, false, false, false)
                SetEntityHeading(ghost, h)
                if ghostChair then
                    local c = AC.chairCoords(ghost, game)
                    SetEntityCoordsNoOffset(ghostChair, c.x, c.y, c.z, false, false, false)
                    SetEntityHeading(ghostChair, h)
                end
            end

            if IsDisabledControlJustPressed(0, 191) and pos then
                local res = lib.callback.await('ta-arcade:admin:place', false, game, pos.x, pos.y, pos.z, h % 360.0, setting)
                if res and res.ok then
                    placed = placed + 1
                    AC.notify(('台 #%d を置きました。続けて置けます'):format(res.id), 'success', 2500)
                else
                    AC.notify(res and res.reason or '置けませんでした', 'error')
                end
            end
            if IsDisabledControlJustPressed(0, 177) or IsDisabledControlJustPressed(0, 202) then
                active = false
            end
            Wait(0)
        end
        lib.hideTextUI()
        DeleteEntity(ghost)
        if ghostChair then DeleteEntity(ghostChair) end
        SetModelAsNoLongerNeeded(g.model)
        if g.chair then SetModelAsNoLongerNeeded(g.chair) end
        AC.busy = false
        -- 終わったら管理画面に戻る
        openAdmin(placed > 0 and ('%d 台置きました'):format(placed) or nil)
    end)
end

---------------------------------------------------------------------------
-- 管理者: 管理画面（NUI）
---------------------------------------------------------------------------

local function gameList()
    local list = {}
    for _, name in ipairs(Config.GameOrder) do
        local g = Config.Games[name]
        if g and AC.games[name] then
            list[#list + 1] = { name = name, label = g.label, settings = g.settings == true, defaultSetting = g.defaultSetting or 1 }
        end
    end
    return list
end

local function adminPayload(extra)
    local list = lib.callback.await('ta-arcade:admin:list', false)
    if not list then return nil end
    local p = GetEntityCoords(cache.ped)
    for _, row in ipairs(list) do
        row.dist = #(vec3(row.x, row.y, row.z) - p)
        row.label = Config.Games[row.game] and Config.Games[row.game].label or row.game
    end
    local payload = {
        action = 'admin', machines = list, games = gameList(),
        -- ゲームごとの数字（管理画面の表示に使う）
        bonusEnd = { big = Config.Slot.Bonus.big.endPay, reg = Config.Slot.Bonus.reg.endPay },
        pachi = { price = Config.Pachi.BallPrice },
        -- 払い戻せずに残っている分（件数と合計）
        unpaid = lib.callback.await('ta-arcade:admin:unpaid', false),
    }
    for k, v in pairs(extra or {}) do payload[k] = v end
    return payload
end

openAdmin = function(message, selectId)
    if AC.busy then return end
    if not lib.callback.await('ta-arcade:isAdmin', false) then
        return AC.notify('管理者だけが使えます', 'error')
    end
    AC.admin = true
    local payload = adminPayload({ message = message, select = selectId })
    if not payload then return end
    adminOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage(payload)
end

openMachineInAdmin = function(id) openAdmin(nil, id) end

RegisterCommand(Config.AdminCommand, function() openAdmin() end, false)

local function closeAdmin()
    adminOpen = false
    SendNUIMessage({ action = 'adminClose' })
    if not AC.busy then SetNuiFocus(false, false) end
end

RegisterNUICallback('admin:close', function(_, cb)
    cb({ ok = true })
    closeAdmin()
end)

RegisterNUICallback('admin:refresh', function(_, cb)
    cb(adminPayload() or { ok = false })
end)

RegisterNUICallback('admin:setting', function(data, cb)
    cb(lib.callback.await('ta-arcade:admin:setting', false, data.id, data.setting) or { ok = false })
end)

RegisterNUICallback('admin:reset', function(data, cb)
    cb(lib.callback.await('ta-arcade:admin:reset', false, data.id) or { ok = false })
end)

RegisterNUICallback('admin:remove', function(data, cb)
    cb(lib.callback.await('ta-arcade:admin:remove', false, data.id) or { ok = false })
end)

RegisterNUICallback('admin:teleport', function(data, cb)
    cb({ ok = true })
    local x, y, z, h = tonumber(data.x), tonumber(data.y), tonumber(data.z), tonumber(data.h) or 0.0
    if not (x and y and z) then return end
    closeAdmin()
    -- 台の正面 1.5m に立つ
    local rad = math.rad(h)
    local px, py = x + math.sin(rad) * 1.5, y - math.cos(rad) * 1.5
    SetEntityCoords(cache.ped, px, py, z, false, false, false, false)
    SetEntityHeading(cache.ped, h)
end)

RegisterNUICallback('admin:place', function(data, cb)
    cb({ ok = true })
    closeAdmin()
    local game = tostring(data.game)
    startPlacement(game, tonumber(data.setting) or (Config.Games[game] and Config.Games[game].defaultSetting) or 1)
end)

---------------------------------------------------------------------------
-- キャラクターの切り替え
---------------------------------------------------------------------------

-- サーバーは同じときに精算して席を空ける。こちらは画面を閉じ、操作を返す
RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    for _, mod in pairs(AC.games) do
        if mod.forceClose then mod.forceClose() end
    end
    if adminOpen then closeAdmin() end
end)
