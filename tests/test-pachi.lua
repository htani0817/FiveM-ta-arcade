-- パチンコ（server/pachi.lua・server/pachi_engine.lua）と、お金の共通処理を FiveM の疑似環境で動かすテスト（fengari / Lua 5.3）
-- node lua-run.js test-pachi.lua
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
local clock = 100000
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
function GetPlayerName(s) return 'player' .. s end
function GetCurrentResourceName() return 'ta-arcade' end
function IsPlayerAceAllowed(s, ace) return (tostring(s) == '1' and ace == 'taArcade.admin') and 1 or 0 end
source = nil

local NEAR, FAR = vec3(0.2, -0.9, 10), vec3(50, 50, 10)
local pedPos = { [1] = FAR, [2] = FAR }
function GetPlayerPed(s) return tonumber(s) end
function GetEntityCoords(ped) return pedPos[ped] end

-- ---- ox_lib ----
local callbacks = {}
lib = { callback = { register = function(name, fn) callbacks[name] = fn end } }
local function call(name, src, ...) return callbacks[name](src, ...) end

-- ---- qbx_core（addFail を true にすると AddMoney が断る） ----
local money = { CID1 = { cash = 0 }, CID2 = { cash = 0 } }
local cidOf = { [1] = 'CID1', [2] = 'CID2' }
local players = {
  [1] = { PlayerData = { source = 1, citizenid = 'CID1' } },
  [2] = { PlayerData = { source = 2, citizenid = 'CID2' } },
}
local addFail = false
local function acct(id) return money[type(id) == 'string' and id or cidOf[id]] end
exports = {
  qbx_core = {
    GetPlayer = function(_, src) return players[src] end,
    GetMoney = function(_, id, kind) return acct(id)[kind] end,
    RemoveMoney = function(_, id, kind, n) local a = acct(id); if a[kind] < n then return false end; a[kind] = a[kind] - n; return true end,
    AddMoney = function(_, id, kind, n) if addFail then return false end; local a = acct(id); a[kind] = a[kind] + n; return true end,
  },
}

-- ---- oxmysql（台の表と未払いの表） ----
local rows, nextId = {}, 1
local unpaid, nextUnpaid = {}, 1
local function find(id) for i, r in ipairs(rows) do if r.id == id then return i, r end end end
local function copy(r) local c = {}; for k, v in pairs(r) do c[k] = v end; return c end
MySQL = {
  query = { await = function(sql, p)
    if sql:find('SHOW TABLES') then return {} end
    if sql:find('FROM ta_arcade_unpaid') then
      if sql:find('COUNT') then
        local total = 0
        for _, u in ipairs(unpaid) do total = total + u.amount end
        return { { n = #unpaid, total = total } }
      end
      local out = {}
      for _, u in ipairs(unpaid) do
        if not sql:find('WHERE citizenid') or u.citizenid == p[1] then out[#out + 1] = copy(u) end
      end
      return out
    end
    if sql:find('FROM ta_arcade_machines') then local out = {}; for _, r in ipairs(rows) do out[#out + 1] = copy(r) end; return out end
    return {}
  end },
  scalar = { await = function() return #rows end },
  insert = setmetatable({ await = function(sql, p)
    local r = { id = nextId, game = p[1], x = p[2], y = p[3], z = p[4], heading = p[5], setting = p[6], data = p[7], created_by = p[8] }
    nextId = nextId + 1
    rows[#rows + 1] = r
    return r.id
  end }, { __call = function(_, sql, p)
    if sql:find('ta_arcade_unpaid') then
      unpaid[#unpaid + 1] = { id = nextUnpaid, citizenid = p[1], amount = p[2], reason = p[3] }
      nextUnpaid = nextUnpaid + 1
    end
  end }),
  update = setmetatable({ await = function(sql, p)
    if sql:find('ta_arcade_unpaid') then
      for i, u in ipairs(unpaid) do if u.id == p[1] then table.remove(unpaid, i) return 1 end end
      return 0
    end
    if sql:find('DELETE') then local i = find(p[1]); if i then table.remove(rows, i) end; return 1 end
  end }, { __call = function(_, sql, p)
    if sql:find('SET setting = %?, data = %?') then
      local _, r = find(p[3]); if r then r.setting, r.data = p[1], p[2] end
    end
  end }),
}

-- ---- 読み込み ----
local function src(name)
  local f, err = load((SOURCES[name]:gsub('`[%w_]+`', '0')), name)
  if not f then error(err) end
  return f
end
src('config.lua')()
src('shared/slot_engine.lua')()
SlotEngine.warmup = function() end
src('server/main.lua')()
src('server/slot.lua')()
src('server/pachi_engine.lua')()
src('server/pachi.lua')()
src('server/start.lua')()
local E = PachiEngine
local C = Config.Pachi
local PRICE = C.BallPrice

-- 乱数は決まった値を返す（rv）。玉の行き先・当たり外れ・ラウンド数がこれで決まる
local rv = 0.99
E.random = function() return rv end

local function eventsOf(name)
  local n = 0
  for _, e in ipairs(clientEvents) do if e.name == name then n = n + 1 end end
  return n
end
local function lastEvent(name)
  for i = #clientEvents, 1, -1 do if clientEvents[i].name == name then return clientEvents[i] end end
end
local function dataOf(id) local _, r = find(id); return r and json.decode(r.data) end
local function P(name) return 'ta-arcade:pachi:' .. name end
local MID
local function shoot(s, ms) clock = clock + (ms or C.ShotInterval); return call(P('shoot'), s, MID) end
local function sync(s, ms) clock = clock + (ms or C.ShotInterval); return call(P('sync'), s, MID) end
local function machine() return Arcade.machines[MID] end
local function resetState() machine().state = E.newState(); machine().state.lampSent = false end
local function hasEvent(res, t)
  for _, e in ipairs(res.events or {}) do if e.t == t then return e end end
end

-- ===== 1. 設置と着席 =====
local r = call('ta-arcade:admin:place', 2, 'pachi', 0, 0, 10, 90, 1)
ok(r.ok == false, '管理者でない人は置けない')
r = call('ta-arcade:admin:place', 1, 'pachi', 0, 0, 10, 90, 1)
MID = r.id
ok(r.ok and rows[1].game == 'pachi', '管理者はパチンコ台を置ける')
r = call(P('sit'), 2, MID)
ok(not r.ok and r.reason:find('離れ'), '遠いと座れない')
pedPos[2] = NEAR
r = call(P('sit'), 2, MID)
ok(r.ok and r.info.balls == 0 and r.info.mode == 'normal' and r.info.admin == nil, '近ければ座れる（持ち玉 0・通常・管理の情報なし）')
pedPos[1] = NEAR
ok(not call(P('sit'), 1, MID).ok, 'ほかの人が座っている台には座れない')
ok(not call(P('shoot'), 1, MID).ok, '座っていない人は打てない')
ok(lastEvent('ta-arcade:machineState').args[2] == true, '使用中が配られる')

-- ===== 2. 玉貸し =====
r = shoot(2)
ok(r.ok and r.stop and r.stop:find('現金') and r.shot == nil and r.info.balls == 0, '現金が無いと打てない（玉は減らない）')
money.CID2.cash = 100000000
r = shoot(2)
ok(r.ok and r.lent == C.LendUnit * PRICE and money.CID2.cash == 100000000 - C.LendUnit * PRICE, ('持ち玉が無ければ %d玉を現金から借りる'):format(C.LendUnit))
ok(r.shot.to == 'miss' and r.shot.pay == 0 and r.info.balls == C.LendUnit - 1, '1発打つと持ち玉が 1 減る')

-- ===== 3. 打ち出しの間隔 =====
local b0 = r.info.balls
r = call(P('shoot'), 2, MID)
ok(r.ok and r.wait == true and r.shot == nil and r.info.balls == b0, '間隔を空けずに打っても玉は出ない（減らない）')
r = shoot(2, C.ShotInterval - 140)
ok(r.shot ~= nil and r.info.balls == b0 - 1, '少しだけ早いのは通信の揺れとして許す')
r = shoot(2, C.ShotInterval - 140)
ok(r.wait == true and r.info.balls == b0 - 1, '早打ちを続けても、平均では速くならない')
local sent0 = eventsOf('ta-arcade:machineState')
clock = clock + 5000
for _ = 1, 10 do shoot(2) end
ok(eventsOf('ta-arcade:machineState') == sent0, '1発ごとには全員へ配らない')

-- ===== 4. ヘソと保留 =====
C.Entry.heso = 1 -- 必ずヘソに入る
rv = 0.5         -- ハズレ・リーチなし
clock = clock + 5000
b0 = call(P('sync'), 2, MID).info.balls
r = shoot(2)
ok(r.shot.to == 'heso' and r.shot.pay == C.Pay.heso and r.info.balls == b0 - 1 + C.Pay.heso, 'ヘソに入ると賞球が出る')
ok(r.info.hold == 1 and r.info.spin == nil and #r.events == 0, '玉が届くまでは変動が始まらない')
ok(machine().state.queue[1].hit == nil, '保留の中に当たり外れは入っていない（変動が始まるときに決める）')
for _ = 1, 3 do r = shoot(2) end
ok(r.info.hold == 4, '保留は 4 個までたまる')
r = shoot(2)
local ev = hasEvent(r, 'spin')
ok(ev and ev.hit == false and r.info.spin and r.info.hold == 4, '玉が届くと変動が始まり、保留が 1 つ減る（打った玉でまた 4 個）')
ok(ev.duration == C.Time.spinShort, '保留が多いときは変動が短い')
r = shoot(2)
ok(r.shot.to == 'heso' and r.shot.pay == C.Pay.heso and r.info.hold == 4, '保留がいっぱいでも賞球は出る（保留は増えない）')

-- ===== 5. 確変当たり =====
C.Entry.heso = 0
rv = 0.001 -- 当たり・確変・ラウンドは振り分けの先頭
local got
for _ = 1, 20 do
  r = sync(2, 1000)
  got = hasEvent(r, 'spin')
  if got and got.hit then break end
end
ok(got and got.hit == true and got.reach == true and got.duration == C.Time.hit, '当たりの変動が始まる')
ok(got.digits[1] == got.digits[2] and got.digits[2] == got.digits[3] and got.digits[1] % 2 == 1, '確変当たりは奇数の図柄が揃う')
ok(r.info.jackpot == nil, '変動が終わるまでは大当たりにならない')
r = sync(2, C.Time.hit)
ev = hasEvent(r, 'jackpot')
ok(ev and ev.kind == 'kakuhen' and r.info.jackpot and r.info.jackpot.rounds == C.Rounds.heso[1][1], '変動が終わると大当たりが始まる')
ok(lastEvent('ta-arcade:machineState').args[3] == true, 'ランプが周りに配られる')
r = shoot(2)
ok(r.shot.to == 'miss' and r.info.jackpot.open == false, 'アタッカーが開くまでは入らない')
clock = clock + C.Time.fanfare
local pays, shots, ended = 0, 0, nil
repeat
  r = shoot(2)
  shots = shots + 1
  if r.shot.to == 'attacker' then pays = pays + r.shot.pay end
  ended = ended or hasEvent(r, 'jackpotEnd')
until not r.info.jackpot or shots > 300
local rounds = C.Rounds.heso[1][1]
ok(pays == rounds * C.RoundCount * C.Pay.attacker, ('%dR で %d 玉の賞球'):format(rounds, rounds * C.RoundCount * C.Pay.attacker))
ok(shots > rounds * C.RoundCount, 'ラウンドの間はアタッカーが閉じていて入らない')
ok(ended and ended.mode == 'kakuhen' and r.info.mode == 'kakuhen', '確変当たりの後は確変になる')
local d = machine().data
ok(d.kakuhen == 1 and d.normal == 0 and d.since == 0 and d.history[1].t == 'kakuhen' and d.history[1].r == rounds, 'データカウンターに数える')

-- ===== 6. 確変は次の当たりまで続く =====
machine().state.queue = {}
C.Entry.denchu = 1
rv = 0.5
local total0 = d.total
for _ = 1, 400 do r = shoot(2) end
ok(r.info.mode == 'kakuhen' and r.info.jackpot == nil and d.total - total0 > C.JitanSpins, ('ハズレが %d 回転続いても確変のまま'):format(d.total - total0))
ok(r.shot.to == 'denchu' and r.shot.pay == C.Pay.denchu, '確変中は電チューに入る')

-- ===== 7. 通常当たりと時短 =====
C.KakuhenRate = 0 -- 当たれば必ず通常当たり
C.Entry.denchu = 0
rv = 0.001
got = nil
for _ = 1, 20 do
  r = sync(2, 1000)
  got = hasEvent(r, 'spin')
  if got and got.hit then break end
end
ok(got and got.digits[1] == got.digits[3] and got.digits[1] % 2 == 0 and got.duration == C.Time.hitSupport, '通常当たりは偶数の図柄が揃う（確変中の変動は短い）')
C.KakuhenRate = 0.5
r = sync(2, C.Time.hitSupport)
ok(r.info.jackpot and r.info.jackpot.kind == 'normal' and r.info.jackpot.rounds == C.Rounds.denchu[1][1], '電チューで当たるとラウンドの振り分けが変わる')
clock = clock + C.Time.fanfare
shots = 0
repeat r = shoot(2); shots = shots + 1 until not r.info.jackpot or shots > 300
ok(r.info.mode == 'jitan' and r.info.jitanLeft == C.JitanSpins, ('通常当たりの後は時短 %d 回転'):format(C.JitanSpins))
ok(lastEvent('ta-arcade:machineState').args[3] == true, '時短中もランプは点いたまま')
machine().state.queue = {}
C.Entry.denchu = 1
rv = 0.5
total0 = d.total
shots, ended = 0, nil
repeat
  r = shoot(2)
  shots = shots + 1
  ended = ended or hasEvent(r, 'jitanEnd')
until r.info.mode == 'normal' or shots > 3000
ok(r.info.mode == 'normal' and ended and d.total - total0 == C.JitanSpins, ('時短は %d 回転で通常に戻る（%d 回転だった）'):format(C.JitanSpins, d.total - total0))
ok(lastEvent('ta-arcade:machineState').args[3] == false, '通常に戻るとランプが消える')
C.Entry.denchu = 0.33

-- ===== 8. 精算 =====
local balls = r.info.balls
local cash0 = money.CID2.cash
r = call(P('leave'), 2)
ok(r.ok and r.yen == balls * PRICE and money.CID2.cash == cash0 + r.yen, '精算で持ち玉を現金に戻す')
ok(lastEvent('ta-arcade:machineState').args[2] == false, '空きが配られる')
ok(call(P('leave'), 2).yen == 0, '座っていないときの精算は 0円')

-- ===== 9. 管理者の「確実に当たり」 =====
ok(not call(P('adminForce'), 2, 'kakuhen').ok, '管理者でない人は使えない')
money.CID1.cash = 100000000
resetState()
r = call(P('sit'), 1, MID)
ok(r.ok and r.info.admin and r.info.admin.setting == 1 and r.info.admin.force == nil, '管理者が座ると管理の情報が付く')
r = call(P('adminForce'), 1, 'kakuhen')
ok(r.ok and r.info.admin.force == 'kakuhen', '確実に当たりを確変に入れられる')
C.Entry.heso = 1
rv = 0.5 -- 普段なら必ずハズレ
shoot(1)
C.Entry.heso = 0
got = nil
for _ = 1, 10 do r = sync(1, 1000); got = hasEvent(r, 'spin'); if got then break end end
ok(got and got.hit == true and got.digits[1] % 2 == 1 and got.digits[1] == got.digits[2], '抽選せずに確変当たりになる')
resetState()
call(P('adminForce'), 1, 'normal')
C.Entry.heso = 1
shoot(1)
C.Entry.heso = 0
got = nil
for _ = 1, 10 do r = sync(1, 1000); got = hasEvent(r, 'spin'); if got then break end end
ok(got and got.hit == true and got.digits[1] % 2 == 0, '通常当たりにも切り替えられる')
resetState()
call(P('adminForce'), 1, nil)
C.Entry.heso = 1
shoot(1)
C.Entry.heso = 0
got = nil
for _ = 1, 10 do r = sync(1, 1000); got = hasEvent(r, 'spin'); if got then break end end
ok(got and got.hit == false, '切にすると普段の抽選に戻る')
r = call(P('adminSetting'), 1, 4)
ok(r.ok and r.info.admin.setting == 4 and rows[1].setting == 4, '打ちながら設定を変えられる')
r = call('ta-arcade:admin:list', 1)
ok(r[1].game == 'pachi' and r[1].data.kakuhen == 1 and r[1].data.owner == nil and r[1].state.mode == 'normal', '管理者はデータと中の状態を見られる（持ち玉の控えは出ない）')
ok(not call('ta-arcade:admin:remove', 1, MID).ok, '遊んでいる人がいる台は撤去できない')
call(P('leave'), 1)

-- ===== 10. 持ち玉の上限 =====
resetState()
local maxBalls = C.MaxBalls
C.MaxBalls = 30
C.Entry.heso = 1
rv = 0.5
call(P('sit'), 2, MID)
cash0 = money.CID2.cash
r = shoot(2); r = shoot(2); r = shoot(2) -- 25 玉借りて、3 発で 24+3 → 29 → 31
ok(r.info.balls == 30 and r.cashOut == 1 * PRICE and money.CID2.cash == cash0 - C.LendUnit * PRICE + PRICE, '上限を超えた玉はその場で現金になる')
C.MaxBalls = maxBalls
C.Entry.heso = 0

-- ===== 11. 払い戻しに失敗したら残して、あとで払い直す =====
addFail = true
cash0 = money.CID2.cash
r = call(P('leave'), 2)
ok(r.yen == 0 and money.CID2.cash == cash0, 'qbx_core が断ると現金は増えない')
ok(#unpaid == 1 and unpaid[1].citizenid == 'CID2' and unpaid[1].amount == 30 * PRICE, '渡せなかった分は未払いとして残る')
r = call('ta-arcade:admin:unpaid', 1)
ok(r.count == 1 and r.total == 30 * PRICE, '管理者は未払いの件数と合計を見られる')
ok(call('ta-arcade:admin:unpaid', 2) == nil, '管理者でない人は見られない')
Arcade.retryUnpaid()
ok(#unpaid == 1 and money.CID2.cash == cash0, 'まだ断られる間は、払い直しても未払いに残る（増えも減りもしない）')
addFail = false
r = call(P('sit'), 2, MID)
ok(r.ok and #unpaid == 0 and money.CID2.cash == cash0 + 30 * PRICE, '次に座ったときに払い直される')

-- ===== 12. サーバーが落ちたときの持ち玉 =====
resetState()
C.Entry.heso = 1
r = shoot(2)
C.Entry.heso = 0
balls = r.info.balls
Arcade.flushDirty() -- 60 秒ごとの書き込み
ok(dataOf(MID).owner and dataOf(MID).owner.cid == 'CID2' and dataOf(MID).owner.balls == balls, '持ち玉と持ち主が DB に控えられる')
cash0 = money.CID2.cash
local _, row = find(MID)
Arcade.machines[MID] = Arcade.newMachine(copy(row)) -- 精算されないまま落ちて、起動し直した
ok(money.CID2.cash == cash0 + balls * PRICE, '起動し直すと、控えてあった持ち玉が持ち主に返る')
ok(dataOf(MID).owner == nil and machine().data.owner == nil, '返した控えは消える（二重に返さない）')
cash0 = money.CID2.cash
Arcade.machines[MID] = Arcade.newMachine(copy(row))
ok(money.CID2.cash == cash0, 'もう一度起動し直しても返さない')

-- ===== 13. キャラクターの切り替え・切断・台から離れる =====
r = call(P('sit'), 1, MID)
ok(r.ok, '落ちた後の台に座れる')
shoot(1)
r = sync(1)
balls = r.info.balls
cash0 = money.CID1.cash
handlers['QBCore:Server:OnPlayerUnload'](1)
ok(money.CID1.cash == cash0 + balls * PRICE, 'キャラクターを切り替えると精算される')
ok(machine().seat == nil and machine().data.owner == nil, '席が空き、持ち玉の控えも消える')
r = call(P('sit'), 1, MID)
ok(r.ok, '切り替えた後、また座れる')
shoot(1)
balls = sync(1).info.balls
cash0 = money.CID1.cash
pedPos[1] = FAR
r = shoot(1)
ok(not r.ok and r.left == true and r.yen == balls * PRICE and money.CID1.cash == cash0 + balls * PRICE, '台から離れて打とうとすると精算して席を空ける')
pedPos[1] = NEAR
call(P('sit'), 1, MID)
shoot(1)
balls = sync(1).info.balls
cash0 = money.CID1.cash
source = 1
handlers['playerDropped']()
ok(money.CID1.cash == cash0 + balls * PRICE and machine().seat == nil, '切断すると citizenid 宛てに精算される')

-- ===== 14. 壊れたデータ =====
local m = Arcade.newMachine({ id = 99, game = 'pachi', x = 0, y = 0, z = 0, heading = 0, setting = 1, data = '{["total"]="x",["history"]=5}' })
ok(m and m.data.total == 0 and type(m.data.history) == 'table' and m.data.kakuhen == 0, '壊れたデータは初期値で埋めて動かす')
m = Arcade.newMachine({ id = 98, game = 'pachi', x = 0, y = 0, z = 0, heading = 0, setting = 1, data = 'こわれた' })
ok(m and m.data.total == 0, 'JSON として読めないデータでも台は出る')

-- ===== 15. エンジン単体: 振り分けと図柄 =====
local seq = {}
E.random = function() return table.remove(seq, 1) or 0.5 end
local st, dd = E.newState(), { total = 0, kakuhen = 0, normal = 0, since = 0, history = {} }
st.queue[1] = { at = 0, via = 'heso' }
seq = { 0.0001, 0.9, 0.95 } -- 当たり・通常当たり・ラウンドは振り分けの後ろ
local evs = {}
E.advance(st, dd, 10, C, 1, nil, evs)
ok(st.spin.hit == 'normal' and st.spin.rounds == C.Rounds.heso[#C.Rounds.heso][1], 'ラウンドは割合どおりに振り分ける')
st, evs = E.newState(), {}
st.queue[1] = { at = 0, via = 'heso' }
seq = { 0.9, 0.01 } -- ハズレ・リーチ
E.advance(st, dd, 10, C, 1, nil, evs)
local g = st.spin.digits
ok(st.spin.hit == nil and st.spin.reach and g[1] == g[3] and g[2] ~= g[1] and evs[1].duration == C.Time.reach, 'リーチハズレは左右が同じで中がずれる')
st, evs = E.newState(), {}
st.queue[1] = { at = 0, via = 'heso' }
seq = { 0.9, 0.9 }
E.advance(st, dd, 10, C, 1, nil, evs)
g = st.spin.digits
ok(st.spin.hit == nil and not st.spin.reach and g[1] ~= g[3], 'ただのハズレは左右が揃わない')

-- ===== 16. 時計の折り返し =====
clock = 2147483000
local t1 = Arcade.now()
clock = -2147483648 + 352 -- 32 ビットの上限を越えて負に戻った（1000 ミリ秒後）
local t2 = Arcade.now()
ok(t2 - t1 == 1000, ('GetGameTimer が負に折り返しても、時刻は続きから進む（差 %s）'):format(tostring(t2 - t1)))
clock = clock + 500
ok(Arcade.now() - t2 == 500, '折り返した後も普段どおり進む')

print(('結果: %d 件 OK、%d 件 NG'):format(pass, fail))
if fail > 0 then error('テスト失敗') end
