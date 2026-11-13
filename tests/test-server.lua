-- server/*.lua を FiveM の疑似環境で動かすテスト（fengari / Lua 5.3）
-- node lua-run.js test-server.lua
local pass, fail = 0, 0
local function ok(cond, msg)
  if cond then pass = pass + 1 else fail = fail + 1; print('NG: ' .. msg) end
end

-- ---- ベクトル ----
local V = {}
V.__index = V
V.__sub = function(a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end
V.__len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end
function vec3(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end

-- ---- json（Lua の表の書き方で往復させるだけ） ----
local function ser(v)
  if type(v) == 'table' then
    local p = {}
    for k, x in pairs(v) do
      p[#p + 1] = (type(k) == 'number' and ('[' .. k .. ']') or ('["' .. k .. '"]')) .. '=' .. ser(x)
    end
    return '{' .. table.concat(p, ',') .. '}'
  elseif type(v) == 'string' then return ('%q'):format(v) end
  return tostring(v)
end
json = { encode = ser, decode = function(s) return load('return ' .. s)() end }

-- ---- FiveM ----
local clock = 10000
function GetGameTimer() return clock end
local mainThreads = {}
function CreateThread(fn)
  local co = coroutine.create(fn)
  local okk, err = coroutine.resume(co)
  if not okk then error(err) end
  if coroutine.status(co) ~= 'dead' then mainThreads[#mainThreads + 1] = co end
end
function Wait() if coroutine.isyieldable() then coroutine.yield() end end
local clientEvents = {}
function TriggerClientEvent(name, target, ...) clientEvents[#clientEvents + 1] = { name = name, target = target, args = { ... } } end
local handlers = {}
function AddEventHandler(name, fn) handlers[name] = fn end
local online = { [1] = true, [2] = true }
function GetPlayerName(s) return online[tonumber(s)] and ('player' .. s) or nil end
function GetCurrentResourceName() return 'ta-arcade' end
function IsPlayerAceAllowed(s, ace) return (tostring(s) == '1' and ace == 'taArcade.admin') and 1 or 0 end
source = nil

local pedPos = { [1] = vec3(5, -1, 10), [2] = vec3(50, 50, 10) }
function GetPlayerPed(s) return tonumber(s) end
function GetEntityCoords(ped) return pedPos[ped] end

-- ---- ox_lib ----
local callbacks = {}
lib = { callback = { register = function(name, fn) callbacks[name] = fn end } }
local function call(name, src, ...) return callbacks[name](src, ...) end

-- ---- qbx_core ----
local money = { CID1 = { cash = 0 }, CID2 = { cash = 0 } }
local cidOf = { [1] = 'CID1', [2] = 'CID2' }
local players = {
  [1] = { PlayerData = { source = 1, citizenid = 'CID1' } },
  [2] = { PlayerData = { source = 2, citizenid = 'CID2' } },
}
local function acct(id) return money[type(id) == 'string' and id or cidOf[id]] end
exports = {
  qbx_core = {
    GetPlayer = function(_, src) return players[src] end,
    GetMoney = function(_, id, kind) return acct(id)[kind] end,
    RemoveMoney = function(_, id, kind, n) local a = acct(id); if a[kind] < n then return false end; a[kind] = a[kind] - n; return true end,
    AddMoney = function(_, id, kind, n) local a = acct(id); a[kind] = a[kind] + n; return true end,
  },
}

-- ---- oxmysql（旧 tani-slot・旧 tani-arcade の表も置ける） ----
local rows, nextId = {}, 1
local oldArcadeRows = nil -- 旧 tani-arcade の表（nil のときは表が無い）
local oldRows = {
  { id = 7, x = 100, y = 200, z = 30, heading = 90, setting = 5, total_games = 321, big_count = 2, reg_count = 1, since_bonus = 40,
    history = ser({ { t = 'big', g = 120 } }), created_by = 'OLD' },
}
local function find(id) for i, r in ipairs(rows) do if r.id == id then return i, r end end end
local function copy(r) local c = {}; for k, v in pairs(r) do c[k] = v end; return c end
MySQL = {
  query = { await = function(sql)
    if sql:find('SHOW TABLES') then
      if sql:find('tani_arcade_machines') then return oldArcadeRows and { { name = 'tani_arcade_machines' } } or {} end
      return #oldRows > 0 and { { name = 'tani_slot_machines' } } or {}
    end
    if sql:find('FROM tani_arcade_machines') then local out = {}; for _, r in ipairs(oldArcadeRows or {}) do out[#out + 1] = copy(r) end; return out end
    if sql:find('FROM tani_slot_machines') then local out = {}; for _, r in ipairs(oldRows) do out[#out + 1] = copy(r) end; return out end
    if sql:find('FROM ta_arcade_machines') then local out = {}; for _, r in ipairs(rows) do out[#out + 1] = copy(r) end; return out end
    return {}
  end },
  scalar = { await = function() return #rows end },
  insert = { await = function(sql, p)
    local r = { id = nextId, game = p[1], x = p[2], y = p[3], z = p[4], heading = p[5], setting = p[6], data = p[7], created_by = p[8] }
    nextId = nextId + 1
    rows[#rows + 1] = r
    return r.id
  end },
  update = setmetatable({ await = function(sql, p)
    if sql:find('DELETE') then local i = find(p[1]); if i then table.remove(rows, i) end; return 1 end
  end }, { __call = function(_, sql, p)
    if sql:find('SET setting = %?, data = %?') then
      local _, r = find(p[3]); if r then r.setting, r.data = p[1], p[2] end
    end
  end }),
}

-- ---- 読み込み ----
-- FiveM のハッシュ文字列 `name` は普通の Lua では読めないので 0 にする
local function src(name)
  local f, err = load((SOURCES[name]:gsub('`[%w_]+`', '0')), name)
  if not f then error(err) end
  return f
end
src('config.lua')()
src('shared/slot_engine.lua')()
SlotEngine.warmup = function() end -- テストでは先回りの計算を省く（必要な分だけ都度計算される）
src('server/main.lua')()
src('server/slot.lua')()
src('server/start.lua')()
local E = SlotEngine
local C = Config.Slot

local function lastEvent(name)
  for i = #clientEvents, 1, -1 do if clientEvents[i].name == name then return clientEvents[i] end end
end
local function dataOf(id) local _, r = find(id); return r and json.decode(r.data) end

-- 狙う役を必ず揃える押し方を探す（目押し）
local function perfectPresses(want)
  for a = 0, 20 do for b = 0, 20 do for c = 0, 20 do
    local pr = { { reel = 1, press = a }, { reel = 2, press = b }, { reel = 3, press = c } }
    local _, got = E.payout(want, E.resolve(want, pr), false)
    if got == want then return pr end
  end end end
end
local function anyPresses() return { { reel = 1, press = 3 }, { reel = 2, press = 9 }, { reel = 3, press = 15 } } end
local function force(tbl) for i = 1, 6 do C.Lottery[i] = tbl end end -- どの設定でも同じ抽選にする
local ALWAYS = 1.0000001
local function S(name) return 'ta-arcade:slot:' .. name end

-- ===== 0. 旧 tani-slot からの引き継ぎ =====
ok(#rows == 1 and rows[1].game == 'slot' and rows[1].setting == 5, '旧 tani-slot の台を 1 台引き継ぐ')
local d0 = dataOf(1)
ok(d0 and d0.total == 321 and d0.big == 2 and d0.history[1].g == 120, '旧いデータ（総回転・BIG・履歴）も引き継ぐ')
ok(Arcade.machines[1] ~= nil, '引き継いだ台が読み込まれる')
call('ta-arcade:admin:remove', 1, 1)
oldRows = {}

-- ===== 1. 台の設置 =====
local r = call('ta-arcade:admin:place', 2, 'slot', 0, 0, 10, 90, 3)
ok(r.ok == false and #rows == 0, '管理者でない人は置けない')
r = call('ta-arcade:admin:place', 1, 'nope', 0, 0, 10, 90, 3)
ok(r.ok == false, '知らないゲームは置けない')
r = call('ta-arcade:admin:place', 1, 'slot', 0, 0, 10, 450, 9)
local MID = r.id
ok(r.ok and MID == 2, '管理者は置ける')
ok(rows[1].heading == 90.0 and rows[1].setting == 6, '向きは 360 で割った余り・設定は 6 まで')
ok(lastEvent('ta-arcade:machines') and #lastEvent('ta-arcade:machines').args[1] == 1, '台の一覧が配られる')
local pub = call('ta-arcade:list', 2)
ok(pub[1].setting == nil and pub[1].game == 'slot', '一覧に設定は入らない')
r = call('ta-arcade:admin:setting', 1, MID, 1)
ok(r.ok and rows[1].setting == 1 and r.row.setting == 1, '設定を変えられる')

-- ===== 2. 着席 =====
r = call(S('sit'), 2, MID)
ok(not r.ok and r.reason:find('離れ'), '遠いと座れない')
pedPos[2] = vec3(0.3, -0.9, 10)
r = call(S('sit'), 2, MID)
ok(r.ok and r.info.credit == 0 and r.info.admin == nil, '近ければ座れる（管理者でなければ管理の情報は無い）')
pedPos[1] = vec3(0.2, -1.0, 10)
r = call(S('sit'), 1, MID)
ok(not r.ok, 'ほかの人が座っている台には座れない')
ok(lastEvent('ta-arcade:machineState').args[2] == true, '使用中が配られる')

-- ===== 3. 掛け金 =====
local P = C.MedalPrice
force({ replay = 0, bell = 0 })
r = call(S('lever'), 2, MID)
ok(not r.ok and r.reason:find('現金'), '現金が無いとレバーを叩けない')
money.CID2.cash = 1000 * P
r = call(S('lever'), 2, MID)
ok(r.ok and money.CID2.cash == 997 * P and r.paidYen == 3 * P, ('3枚分 %d円を現金から払う'):format(3 * P))
ok(r.want == nil and r.stops == nil, 'ハズレ')
r = call(S('lever'), 2, MID)
ok(not r.ok, '回っている間はもう一度叩けない')
r = call(S('stop'), 2, MID, { { reel = 1, press = 0 }, { reel = 1, press = 1 }, { reel = 3, press = 2 } })
ok(r.ok and r.fixed and r.pay == 0, '同じリールを2回押すような不正な押し方は順押し 0 にする')
r = call(S('lever'), 2, MID)
ok(not r.ok and r.reason == 'wait', '4.1秒たたないと次を回せない')
clock = clock + 4000
r = call(S('lever'), 2, MID)
ok(r.ok, '少しだけ早くても通信の揺れの分は許す（3.95秒）')
call(S('stop'), 2, MID, anyPresses())

-- ===== 4. ベル・リプレイ =====
force({ bell = ALWAYS })
clock = clock + 5000
r = call(S('lever'), 2, MID)
ok(r.want == 'bell', 'ベルが当たる')
r = call(S('stop'), 2, MID, anyPresses())
ok(r.ok and r.got == 'bell' and r.pay == 8 and r.info.credit == 8, 'ベルはどこを押しても揃い 8 枚がクレジットへ')
local cash0 = money.CID2.cash
clock = clock + 5000
r = call(S('lever'), 2, MID)
ok(money.CID2.cash == cash0 and r.info.credit == 5, 'クレジットがあれば現金は減らない')
call(S('stop'), 2, MID, anyPresses())
force({ replay = ALWAYS })
clock = clock + 5000
call(S('lever'), 2, MID)
r = call(S('stop'), 2, MID, anyPresses())
ok(r.got == 'replay' and r.info.replay == true, 'リプレイが揃う')
local credit0 = r.info.credit
force({})
clock = clock + 5000
r = call(S('lever'), 2, MID)
ok(r.ok and r.info.credit == credit0, 'リプレイの次は掛け金なし')
call(S('stop'), 2, MID, anyPresses())

-- ===== 5. ハズレでは何も揃わない =====
local badCount = 0
for i = 1, 30 do
  clock = clock + 5000
  call(S('lever'), 2, MID)
  r = call(S('stop'), 2, MID, { { reel = (i % 3) + 1, press = (i * 7) % 21 }, { reel = ((i + 1) % 3) + 1, press = (i * 5) % 21 }, { reel = ((i + 2) % 3) + 1, press = (i * 11) % 21 } })
  if r.pay ~= 0 or r.got then badCount = badCount + 1 end
end
ok(badCount == 0, 'ハズレの 30 ゲームで何も揃わない')

-- ===== 6. BIG（持ち越し・告知ランプ・目押し・消化） =====
force({ big = ALWAYS })
C.LampPreChance = 0
clock = clock + 5000
r = call(S('lever'), 2, MID)
ok(r.want == 'big' and r.info.lamp == false, 'BIG が当たる（まだ光らない）')
local miss
for a = 0, 20 do
  local pr = { { reel = 1, press = a }, { reel = 2, press = a }, { reel = 3, press = a } }
  local _, got = E.payout('big', E.resolve('big', pr), false)
  if got ~= 'big' then miss = pr break end
end
r = call(S('stop'), 2, MID, miss)
ok(r.got == nil and r.info.lamp == true, '揃わなければ第3停止の後に告知ランプが光る')
ok(lastEvent('ta-arcade:machineState').args[3] == true, 'ランプが周りに配られる')
force({})
clock = clock + 5000
r = call(S('lever'), 2, MID)
ok(r.want == 'big', 'BIG を持ち越す')
r = call(S('stop'), 2, MID, perfectPresses('big'))
ok(r.got == 'big' and r.started == 'big' and r.info.mode == 'big' and r.info.lamp == false, '目押しで 7 が揃い BIG が始まる')
local games, paid = 0, 0
cash0 = money.CID2.cash
repeat
  clock = clock + 5000
  call(S('lever'), 2, MID)
  r = call(S('stop'), 2, MID, anyPresses())
  games, paid = games + 1, paid + r.pay
until r.info.mode == 'normal' or games > 60
ok(r.info.mode == 'normal' and paid >= C.Bonus.big.endPay, ('BIG は %d 枚を超えたら終わる（%d ゲームで %d 枚）'):format(C.Bonus.big.endPay, games, paid))
ok(money.CID2.cash > cash0 and r.info.credit <= C.MaxCredit, 'クレジットからあふれた分は現金で受け取る')

-- ===== 7. 精算 =====
local credit = r.info.credit
cash0 = money.CID2.cash
r = call(S('leave'), 2)
ok(r.ok and r.yen == credit * P and money.CID2.cash == cash0 + r.yen, '精算でクレジットを現金に戻す')

-- ===== 8. 管理者の「確実に当たり」 =====
r = call(S('adminForce'), 2, 'big')
ok(not r.ok, '管理者でない人は使えない')
money.CID1.cash = 1000 * P
r = call(S('sit'), 1, MID)
ok(r.ok and r.info.admin and r.info.admin.setting == 1 and r.info.admin.force == nil, '管理者が座ると管理の情報が付く')
r = call(S('adminForce'), 1, 'big')
ok(r.ok and r.info.admin.force == 'big', '確実に当たりを BIG に入れられる')
force({}) -- 普段なら必ずハズレの設定でも
clock = clock + 5000
r = call(S('lever'), 1, MID)
ok(r.want == 'big' and r.stops ~= nil and r.info.lamp == true, '抽選せずに BIG が当たり、揃う位置とランプが来る')
r = call(S('stop'), 1, MID, anyPresses())
ok(r.got == 'big' and r.started == 'big', 'どこを押しても BIG が揃う')
repeat clock = clock + 5000; call(S('lever'), 1, MID); r = call(S('stop'), 1, MID, anyPresses()) until r.info.mode == 'normal'
call(S('adminForce'), 1, 'reg')
clock = clock + 5000
call(S('lever'), 1, MID)
r = call(S('stop'), 1, MID, anyPresses())
ok(r.got == 'reg', 'REG にも切り替えられる')
repeat clock = clock + 5000; call(S('lever'), 1, MID); r = call(S('stop'), 1, MID, anyPresses()) until r.info.mode == 'normal'
call(S('adminForce'), 1, nil)
clock = clock + 5000
r = call(S('lever'), 1, MID)
ok(r.want == nil and r.stops == nil, '切にすると普段の抽選に戻る')
call(S('stop'), 1, MID, anyPresses())
r = call(S('adminSetting'), 1, 4)
ok(r.ok and r.info.admin.setting == 4 and rows[1].setting == 4, '打ちながら設定を変えられる')
call(S('leave'), 1)

-- ===== 9. 回している途中で落ちた =====
call(S('sit'), 2, MID)
force({ bell = ALWAYS })
clock = clock + 5000
call(S('lever'), 2, MID)
cash0 = money.CID2.cash
online[2] = nil
source = 2
handlers['playerDropped']()
ok(money.CID2.cash == cash0 + 8 * P, '落ちたら途中のゲームを止めた扱いにして、払い出しを citizenid に渡す')
r = call(S('sit'), 1, MID)
ok(r.ok, '落ちた人の席は空く')

-- ===== 10. 管理 =====
r = call('ta-arcade:admin:remove', 1, MID)
ok(not r.ok, '遊んでいる人がいる台は撤去できない')
call(S('leave'), 1)
for _, co in ipairs(mainThreads) do for _ = 1, 12 do coroutine.resume(co) end end -- 60 秒ごとの書き戻しまで進める
local dd = dataOf(MID)
ok(dd.total > 30 and dd.big == 2 and dd.reg == 1, ('データが DB に書き戻される（総回転 %d・BIG %d・REG %d）'):format(dd.total, dd.big, dd.reg))
ok(call('ta-arcade:admin:list', 2) == nil, '管理者でない人は一覧を見られない')
r = call('ta-arcade:admin:list', 1)
ok(r[1].setting == 4 and r[1].data.big == 2 and r[1].state.mode == 'normal', '管理者は設定・データ・中の状態を見られる')
r = call('ta-arcade:admin:reset', 1, MID)
ok(r.ok and dataOf(MID).total == 0 and r.row.data.total == 0, 'データを消せる')
r = call('ta-arcade:admin:remove', 1, MID)
ok(r.ok and #rows == 0, '撤去できる')

-- ===== 旧 tani-arcade からの引き継ぎ =====
oldArcadeRows = {
  { id = 3, game = 'slot', x = 1, y = 2, z = 3, heading = 180, setting = 6, data = json.encode({ total = 50, big = 1, reg = 0, since = 5, history = {} }), created_by = 'A' },
  { id = 9, game = 'slot', x = 4, y = 5, z = 6, heading = 0, setting = 2, data = json.encode({ total = 7, big = 0, reg = 0, since = 7, history = {} }), created_by = 'B' },
}
Arcade.migrateOldTables()
ok(#rows == 2 and rows[1].setting == 6 and rows[2].created_by == 'B' and json.decode(rows[1].data).total == 50, '旧 tani-arcade の台を設定・データごと引き継ぐ（tani-slot の表があっても見ない）')
Arcade.migrateOldTables()
ok(#rows == 2, '新しい表に台があれば、もう写さない')
rows = {}; oldArcadeRows = {}
Arcade.migrateOldTables()
ok(#rows == 0, '旧 tani-arcade の表が空なら、tani-slot の表があっても写さない')

print(('結果: %d 件 OK、%d 件 NG'):format(pass, fail))
if fail > 0 then error('テスト失敗') end
