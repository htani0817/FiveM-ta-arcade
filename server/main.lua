-- ta-arcade サーバーの共通部分: 台の置き場所（DB）、管理者の操作、ゲームの登録口
-- ゲームは Arcade.registerGame(名前, 処理) で登録する（server/slot.lua が見本）。起動の処理は server/start.lua
Arcade = {
    machines = {}, -- [id] = { id, game, coords, heading, setting, data, seat, state }
    games = {},    -- [名前] = ゲームの処理
    dirty = {},    -- DB に書き戻す台
}
local A = Arcade

-- IsPlayerAceAllowed は true ではなく 1 を返す（2026-11-11 に実機で確認）。どちらでも通す
function A.isAdmin(src)
    local allowed = IsPlayerAceAllowed(tostring(src), Config.AdminAce)
    return allowed == true or allowed == 1
end

-- 今の時刻（ミリ秒）。戻らない時計にする
-- GetGameTimer が 32 ビットで折り返す場合（約 24.8 日で負の数に戻る。実機では未確認）でも、
-- 前より小さくなったら 2^32 を足して続きから数える。折り返さないなら何もしないのと同じ
local timerBase, timerLast = 0, nil
function A.now()
    local t = GetGameTimer()
    if timerLast and t < timerLast then timerBase = timerBase + 4294967296 end
    timerLast = t
    return timerBase + t
end

function A.clampSetting(s)
    s = math.floor(tonumber(s) or 1)
    if s < 1 then s = 1 elseif s > 6 then s = 6 end
    return s
end

-- ゲームの処理に要るもの:
--   emptyData()           データカウンターの初期値
--   init(m)               台の中の状態（m.state）を作る
--   lamp(m)               周りに見せるランプが点いているか
--   publicData(m)         座っていない人にも見せるデータ
--   adminState(m)         管理者だけに見せる中の状態
--   onDrop(src)           切断・キャラクターの切り替えのとき（座っていたら精算する）
--   onStop()              リソースの停止のとき（座っている全員を精算する）
--   warmup(step)          起動時の先回りの計算（任意）
function A.registerGame(name, mod)
    A.games[name] = mod
end

---------------------------------------------------------------------------
-- お金を渡す（どのゲームもここを通す）
---------------------------------------------------------------------------

-- citizenid 宛てに現金を渡す（落ちた後でも qbx_core がオフラインの人に保存する）。戻り値: 渡せた金額
-- 渡せなかったとき（qbx_core が断った・止まっている）は ta_arcade_unpaid に残し、あとで払い直す
function A.pay(citizenid, yen, reason)
    yen = math.floor(tonumber(yen) or 0)
    if yen <= 0 or not citizenid then return 0 end
    local ok, done = pcall(function() return exports.qbx_core:AddMoney(citizenid, 'cash', yen, reason) end)
    if ok and done then return yen end
    print(('[ta-arcade] 払い戻しに失敗しました: %s に %d円（%s）。未払いとして残します'):format(tostring(citizenid), yen, tostring(reason)))
    MySQL.insert('INSERT INTO ta_arcade_unpaid (citizenid, amount, reason) VALUES (?, ?, ?)', { citizenid, yen, reason })
    return 0
end

-- 未払いを払い直す。citizenid を渡すとその人の分だけ、渡さなければ全員の分。戻り値: 払えた金額
-- 中で DB を待つので、席を確保するような処理の途中では呼ばない（別のスレッドから呼ぶ）
function A.retryUnpaid(citizenid)
    local rows
    if citizenid then
        rows = MySQL.query.await('SELECT id, citizenid, amount, reason FROM ta_arcade_unpaid WHERE citizenid = ?', { citizenid })
    else
        rows = MySQL.query.await('SELECT id, citizenid, amount, reason FROM ta_arcade_unpaid')
    end
    local paid = 0
    for _, r in ipairs(rows or {}) do
        -- 先に行を消し、消せたときだけ払う（同時に 2 か所から払い直しても二重に払わない）。払えなければ A.pay がまた残す
        if MySQL.update.await('DELETE FROM ta_arcade_unpaid WHERE id = ?', { r.id }) == 1 then
            paid = paid + A.pay(r.citizenid, r.amount, r.reason)
        end
    end
    if paid > 0 then print(('[ta-arcade] 未払いだった %d円を払い直しました'):format(paid)) end
    return paid
end

-- 座った後に呼ぶ: その人の未払いがあれば払い直す（席の確保を待たせないよう別のスレッドで）
function A.retryUnpaidLater(citizenid)
    CreateThread(function() A.retryUnpaid(citizenid) end)
end

function A.markDirty(m) A.dirty[m.id] = true end

function A.newMachine(row)
    local mod = A.games[row.game]
    if not mod then return nil end
    local data = nil
    if row.data and row.data ~= '' then
        local ok, d = pcall(json.decode, row.data)
        if ok and type(d) == 'table' then data = d end
    end
    local m = {
        id = row.id,
        game = row.game,
        coords = vec3(row.x + 0.0, row.y + 0.0, row.z + 0.0),
        heading = row.heading + 0.0,
        setting = A.clampSetting(row.setting),
        data = data or mod.emptyData(),
        seat = nil,
    }
    mod.init(m)
    return m
end

function A.publicList()
    local list = {}
    for id, m in pairs(A.machines) do
        list[#list + 1] = {
            id = id, game = m.game, x = m.coords.x, y = m.coords.y, z = m.coords.z, h = m.heading,
            busy = m.seat ~= nil, lamp = A.games[m.game].lamp(m),
        }
    end
    return list
end

function A.broadcastList()
    TriggerClientEvent('ta-arcade:machines', -1, A.publicList())
end

function A.broadcastState(m)
    TriggerClientEvent('ta-arcade:machineState', -1, m.id, m.seat ~= nil, A.games[m.game].lamp(m))
end

function A.saveMachine(m)
    MySQL.update('UPDATE ta_arcade_machines SET setting = ?, data = ? WHERE id = ?', { m.setting, json.encode(m.data), m.id })
end

function A.flushDirty()
    for id in pairs(A.dirty) do
        if A.machines[id] then A.saveMachine(A.machines[id]) end
        A.dirty[id] = nil
    end
end

function A.distanceOk(src, m)
    return #(GetEntityCoords(GetPlayerPed(src)) - m.coords) <= Config.UseDistance
end

---------------------------------------------------------------------------
-- だれでも
---------------------------------------------------------------------------

lib.callback.register('ta-arcade:list', function()
    return A.publicList()
end)

lib.callback.register('ta-arcade:isAdmin', function(src)
    return A.isAdmin(src)
end)

lib.callback.register('ta-arcade:data', function(_, id)
    local m = A.machines[tonumber(id)]
    return m and { game = m.game, data = A.games[m.game].publicData(m) } or nil
end)

AddEventHandler('playerDropped', function()
    local src = source
    for _, mod in pairs(A.games) do mod.onDrop(src) end
end)

-- キャラクターを切り替えた（切断はしていない）。qbx_core にまだ登録が残っているうちに精算して席を空ける
AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    src = tonumber(src)
    if not src then return end
    for _, mod in pairs(A.games) do mod.onDrop(src) end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, mod in pairs(A.games) do mod.onStop() end
    A.flushDirty()
end)

---------------------------------------------------------------------------
-- 管理者
---------------------------------------------------------------------------

local function adminOnly(src)
    if A.isAdmin(src) then return true end
    print(('[ta-arcade] 管理者ではない人（%s）が管理の操作をしようとしました'):format(src))
    return false
end
A.adminOnly = adminOnly

local function adminRow(m)
    local seatName = m.seat and GetPlayerName(m.seat) or nil
    return {
        id = m.id, game = m.game, x = m.coords.x, y = m.coords.y, z = m.coords.z, h = m.heading,
        setting = m.setting, busy = m.seat ~= nil, seatName = seatName,
        lamp = A.games[m.game].lamp(m),
        data = A.games[m.game].publicData(m),
        state = A.games[m.game].adminState(m),
    }
end
A.adminRow = adminRow

lib.callback.register('ta-arcade:admin:list', function(src)
    if not adminOnly(src) then return nil end
    local list = {}
    for _, m in pairs(A.machines) do list[#list + 1] = adminRow(m) end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end)

-- 払い戻せずに残っている分（件数と合計）。管理画面に出す
lib.callback.register('ta-arcade:admin:unpaid', function(src)
    if not adminOnly(src) then return nil end
    local r = MySQL.query.await('SELECT COUNT(*) AS n, COALESCE(SUM(amount), 0) AS total FROM ta_arcade_unpaid')
    local row = r and r[1] or {}
    return { count = tonumber(row.n) or 0, total = tonumber(row.total) or 0 }
end)

lib.callback.register('ta-arcade:admin:place', function(src, game, x, y, z, h, setting)
    if not adminOnly(src) then return { ok = false } end
    if not A.games[game] or not Config.Games[game] then return { ok = false, reason = 'このゲームはありません' } end
    x, y, z, h = tonumber(x), tonumber(y), tonumber(z), tonumber(h)
    if not (x and y and z and h) then return { ok = false, reason = '位置が正しくありません' } end
    setting = A.clampSetting(setting)
    h = h % 360.0
    local player = exports.qbx_core:GetPlayer(src)
    local by = player and player.PlayerData.citizenid or GetPlayerName(src)
    local data = A.games[game].emptyData()
    local id = MySQL.insert.await('INSERT INTO ta_arcade_machines (game, x, y, z, heading, setting, data, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', {
        game, x, y, z, h, setting, json.encode(data), by,
    })
    if not id then return { ok = false, reason = 'DB に保存できませんでした' } end
    A.machines[id] = A.newMachine({ id = id, game = game, x = x, y = y, z = z, heading = h, setting = setting, data = json.encode(data) })
    A.broadcastList()
    return { ok = true, id = id }
end)

lib.callback.register('ta-arcade:admin:setting', function(src, id, setting)
    if not adminOnly(src) then return { ok = false } end
    local m = A.machines[tonumber(id)]
    if not m then return { ok = false, reason = 'この台はありません' } end
    m.setting = A.clampSetting(setting)
    A.saveMachine(m)
    return { ok = true, row = adminRow(m) }
end)

lib.callback.register('ta-arcade:admin:reset', function(src, id)
    if not adminOnly(src) then return { ok = false } end
    local m = A.machines[tonumber(id)]
    if not m then return { ok = false, reason = 'この台はありません' } end
    m.data = A.games[m.game].emptyData()
    A.saveMachine(m)
    return { ok = true, row = adminRow(m) }
end)

lib.callback.register('ta-arcade:admin:remove', function(src, id)
    if not adminOnly(src) then return { ok = false } end
    id = tonumber(id)
    local m = A.machines[id]
    if not m then return { ok = false, reason = 'この台はありません' } end
    if m.seat then return { ok = false, reason = '遊んでいる人がいるので撤去できません' } end
    MySQL.update.await('DELETE FROM ta_arcade_machines WHERE id = ?', { id })
    A.machines[id] = nil
    A.dirty[id] = nil
    A.broadcastList()
    return { ok = true }
end)
