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
src('shared/pachi_board.lua')()
src('server/main.lua')()
src('server/slot.lua')()
src('server/pachi_physics.lua')()
src('server/pachi_engine.lua')()
src('server/pachi.lua')()
src('server/start.lua')()
local E = PachiEngine
local C = Config.Pachi
local T = C.Time
local PRICE = C.BallPrice

-- 乱数は決まった値を返す（rv）。当たり外れ・演出・ラウンド数がこれで決まる
local rv = 0.99
E.random = function() return rv end

-- 物理計算の代わりに、決めた行き先（nextTo）と時間（FT）を返す。入賞口の開閉は本物と同じ聞き方をする
local realSimulate = E.simulate
local nextTo, FT = 'miss', 1000
E.simulate = function(power, gates)
  local to = nextTo
  if to == 'denchu' and not gates.denchu then to = 'miss' end
  if to == 'attacker' and not gates.attacker(FT) then to = 'miss' end
  return { to = to, t = FT, path = { 100, 200, 110, 260 }, hits = { 1 }, power = power }
end

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
local function shoot(s, ms, power) clock = clock + (ms or C.ShotInterval); return call(P('shoot'), s, MID, power or 30) end
local function sync(s, ms) clock = clock + (ms or C.ShotInterval); return call(P('sync'), s, MID) end
local function machine() return Arcade.machines[MID] end
local function resetState() machine().state = E.newState(); machine().state.lampSent = false end
local function hasEvent(res, t)
  for _, e in ipairs(res.events or {}) do if e.t == t then return e end end
end
-- 変動が始まる知らせが来るまで進める
local function waitSpin(s)
  for _ = 1, 30 do
    local r = sync(s, 500)
    local ev = hasEvent(r, 'spin')
    if ev then return ev, r end
  end
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
r = call(P('shoot'), 1, MID, 30)
ok(not r.ok and r.left == true, '座っていない人は打てない（画面を閉じさせる）')
ok(lastEvent('ta-arcade:machineState').args[2] == true, '使用中が配られる')

-- ===== 2. 玉貸し =====
r = shoot(2)
ok(r.ok and r.stop and r.stop:find('現金') and r.shot == nil and r.info.balls == 0, '現金が無いと打てない（玉は減らない）')
money.CID2.cash = 100000000
r = shoot(2)
ok(r.ok and r.lent == C.LendUnit * PRICE and money.CID2.cash == 100000000 - C.LendUnit * PRICE, ('持ち玉が無ければ %d玉を現金から借りる'):format(C.LendUnit))
ok(r.shot.to == 'miss' and r.shot.pay == 0 and r.info.balls == C.LendUnit - 1, '1発打つと持ち玉が 1 減る')
ok(type(r.shot.path) == 'table' and #r.shot.path >= 4 and r.shot.t == FT, '玉の軌道と、届くまでの時間が返る')

-- ===== 3. 打ち出しの間隔とハンドルの強さ =====
local b0 = r.info.balls
r = call(P('shoot'), 2, MID, 30)
ok(r.ok and r.wait == true and r.shot == nil and r.info.balls == b0, '間隔を空けずに打っても玉は出ない（減らない）')
r = shoot(2, C.ShotInterval - 140)
ok(r.shot ~= nil and r.info.balls == b0 - 1, '少しだけ早いのは通信の揺れとして許す')
r = shoot(2, C.ShotInterval - 140)
ok(r.wait == true and r.info.balls == b0 - 1, '早打ちを続けても、平均では速くならない')
local seen = {}
local stub = E.simulate
E.simulate = function(power, gates) seen[#seen + 1] = power; return stub(power, gates) end
clock = clock + 5000
shoot(2, nil, 250); shoot(2, nil, -40); shoot(2, nil, 'abc'); shoot(2, nil, 41.7)
E.simulate = stub
ok(seen[1] == 100 and seen[2] == 0 and seen[3] == 0 and seen[4] == 41, 'ハンドルの強さは 0〜100 の整数に直す（おかしな値は 0）')
local sent0 = eventsOf('ta-arcade:machineState')
for _ = 1, 10 do shoot(2) end
ok(eventsOf('ta-arcade:machineState') == sent0, '1発ごとには全員へ配らない')

-- ===== 4. ヘソと保留（賞球は玉が届いた時刻に入る） =====
sync(2, 3000) -- 飛んでいる玉を全部落とす
nextTo = 'heso'
rv = 0.5 -- ハズレ・リーチなし・保留は白
b0 = call(P('sync'), 2, MID).info.balls
r = shoot(2)
ok(r.shot.to == 'heso' and r.shot.pay == C.Pay.heso and r.info.balls == b0 - 1, 'ヘソへ向かう玉を打った（まだ賞球は入らない）')
ok(r.info.inflight == C.Pay.heso and r.info.flying == 1 and r.info.hold == 0 and #r.events == 0, '届くまでは、賞球も保留も変動も無い')
nextTo = 'miss'
r = sync(2, FT)
local ev = hasEvent(r, 'spin')
ok(r.info.balls == b0 - 1 + C.Pay.heso and r.info.inflight == 0, '玉が届くと賞球が入る')
ok(ev and ev.hit == false and ev.stage == 'none' and ev.duration == T.spin and ev.hot == 'white' and r.info.spin, '届いた玉で変動が始まる')
nextTo = 'heso'
for _ = 1, 6 do r = shoot(2) end
nextTo = 'miss'
b0 = r.info.balls
r = sync(2, FT + 100)
ok(r.info.hold == 4 and #r.info.holds == 4, '保留は 4 個までたまる')
ok(r.info.balls - b0 == 2 * C.Pay.heso and r.info.inflight == 0, '保留がいっぱいのときに届いた玉にも賞球は出る')
ok(machine().state.queue[1].hit == nil and machine().state.queue[1].r ~= nil, '保留には抽選の乱数だけが入り、当たり外れは変動が始まるときに決まる')

-- ===== 5. 確変当たり・保留の色・全回転 =====
resetState()
rv = 0.001 -- 当たり・確変・全回転・ラウンドは振り分けの先頭・保留は赤
nextTo = 'heso'
shoot(2)
nextTo = 'miss'
local got = waitSpin(2)
ok(got and got.hit == true and got.stage == 'full' and got.duration == T.full + T.hitTail, '当たりの変動が始まる（全回転）')
ok(got.hot == 'red', '当たりの保留は色が変わる（先読み）')
ok(got.digits[1] == got.digits[2] and got.digits[2] == got.digits[3] and got.digits[1] % 2 == 1, '確変当たりは奇数の図柄が揃う')
rv = 0.5
r = sync(2, 100)
ok(r.info.jackpot == nil, '変動が終わるまでは大当たりにならない')
nextTo = 'attacker'
r = shoot(2)
ok(r.shot.to == 'miss', '変動中に打った玉は、アタッカーが開く前に届くので入らない')
nextTo = 'miss'
r = sync(2, got.duration)
ev = hasEvent(r, 'jackpot')
local rounds = C.Rounds.heso[1][1]
ok(ev and ev.kind == 'kakuhen' and r.info.jackpot and r.info.jackpot.rounds == rounds and r.info.jackpot.open == false, '変動が終わると大当たりが始まる（アタッカーはまだ閉じている）')
ok(lastEvent('ta-arcade:machineState').args[3] == true, 'ランプが周りに配られる')
clock = clock + T.fanfare
nextTo = 'attacker'
b0 = sync(2, 0).info.balls
local entries, shots, ended = 0, 0, nil
repeat
  r = shoot(2)
  shots = shots + 1
  if r.shot and r.shot.to == 'attacker' then entries = entries + 1 end
  ended = ended or hasEvent(r, 'jackpotEnd')
until not r.info.jackpot or shots > 300
nextTo = 'miss'
ok(entries == rounds * C.RoundCount, ('%dR で %d 個が入る（%d 発打った）'):format(rounds, rounds * C.RoundCount, shots))
ok(shots > entries, 'ラウンドの間に届いた玉は入らない')
ok(ended and ended.mode == 'kakuhen' and r.info.mode == 'kakuhen', '確変当たりの後は確変になる')
r = sync(2, 3000)
ok(r.info.balls == b0 - shots + entries * C.Pay.attacker, ('賞球は %d 玉（1個 %d 玉）'):format(entries * C.Pay.attacker, C.Pay.attacker))
local d = machine().data
ok(d.kakuhen == 1 and d.normal == 0 and d.history[1].t == 'kakuhen' and d.history[1].r == rounds, 'データカウンターに数える')

-- ===== 6. 確変は次の当たりまで続く・電チュー =====
machine().state.queue = {}
nextTo = 'denchu'
rv = 0.5
local total0 = d.total
for _ = 1, 400 do r = shoot(2) end
ok(r.info.mode == 'kakuhen' and r.info.jackpot == nil and d.total - total0 > C.JitanSpins, ('ハズレが %d 回転続いても確変のまま'):format(d.total - total0))
ok(r.shot.to == 'denchu' and r.shot.pay == C.Pay.denchu, '確変中は電チューが開いていて入る')

-- ===== 7. 通常当たりと時短 =====
nextTo = 'miss'
sync(2, 5000)
machine().state.queue = {}
C.KakuhenRate = 0 -- 当たれば必ず通常当たり
rv = 0.001
nextTo = 'denchu'
shoot(2)
nextTo = 'miss'
got = waitSpin(2)
ok(got and got.hit and got.digits[1] == got.digits[3] and got.digits[1] % 2 == 0 and got.duration == T.fullSupport + T.hitTail, '通常当たりは偶数の図柄が揃う（確変中の変動は短い）')
C.KakuhenRate = 0.5
rv = 0.5
r = sync(2, got.duration)
ok(r.info.jackpot and r.info.jackpot.kind == 'normal', '通常当たりの大当たりが始まる')
rounds = r.info.jackpot.rounds
clock = clock + T.fanfare
nextTo = 'attacker'
shots = 0
repeat r = shoot(2); shots = shots + 1 until not r.info.jackpot or shots > 300
ok(r.info.mode == 'jitan' and r.info.jitanLeft == C.JitanSpins, ('通常当たりの後は時短 %d 回転'):format(C.JitanSpins))
ok(lastEvent('ta-arcade:machineState').args[3] == true, '時短中もランプは点いたまま')
nextTo = 'miss'
sync(2, 3000)
machine().state.queue = {}
nextTo = 'denchu'
total0 = d.total
shots, ended = 0, nil
repeat
  r = shoot(2)
  shots = shots + 1
  ended = ended or hasEvent(r, 'jitanEnd')
until r.info.mode == 'normal' or shots > 3000
ok(r.info.mode == 'normal' and ended and d.total - total0 == C.JitanSpins, ('時短は %d 回転で通常に戻る（%d 回転だった）'):format(C.JitanSpins, d.total - total0))
ok(lastEvent('ta-arcade:machineState').args[3] == false, '通常に戻るとランプが消える')
r = shoot(2)
ok(r.shot.to == 'miss', '通常時は電チューが閉じていて入らない')
nextTo = 'attacker'
r = shoot(2)
ok(r.shot.to == 'miss', '通常時はアタッカーが閉じていて入らない')
nextTo = 'miss'

-- ===== 8. 精算（飛んでいる玉の賞球も受け取る） =====
sync(2, 3000)
nextTo = 'heso'
r = shoot(2)
nextTo = 'miss'
local balls = r.info.balls
local cash0 = money.CID2.cash
r = call(P('leave'), 2)
ok(r.ok and r.yen == (balls + C.Pay.heso) * PRICE and money.CID2.cash == cash0 + r.yen, '精算で、持ち玉と飛んでいる玉の賞球を現金に戻す')
ok(lastEvent('ta-arcade:machineState').args[2] == false, '空きが配られる')
ok(call(P('leave'), 2).yen == 0, '座っていないときの精算は 0円')
cash0 = money.CID2.cash
clock = clock + 5000
call(P('sit'), 2, MID)
r = sync(2, 600)
ok(r.info.balls == 0 and r.info.hold + (r.info.spin and 1 or 0) >= 1, '残った玉は届けば保留になるが、賞球を二重には渡さない')
call(P('leave'), 2)
ok(money.CID2.cash == cash0, '（座り直して立っても現金は増えない）')

-- ===== 9. 管理者の「確実に当たり」 =====
ok(not call(P('adminForce'), 2, 'kakuhen').ok, '管理者でない人は使えない')
money.CID1.cash = 100000000
resetState()
r = call(P('sit'), 1, MID)
ok(r.ok and r.info.admin and r.info.admin.setting == 1 and r.info.admin.force == nil, '管理者が座ると管理の情報が付く')
r = call(P('adminForce'), 1, 'kakuhen')
ok(r.ok and r.info.admin.force == 'kakuhen', '確実に当たりを確変に入れられる')
rv = 0.5 -- 普段なら必ずハズレ
nextTo = 'heso'
shoot(1)
nextTo = 'miss'
got = waitSpin(1)
ok(got and got.hit == true and got.digits[1] % 2 == 1 and got.digits[1] == got.digits[2], '抽選せずに確変当たりになる')
resetState()
call(P('adminForce'), 1, 'normal')
nextTo = 'heso'
shoot(1)
nextTo = 'miss'
got = waitSpin(1)
ok(got and got.hit == true and got.digits[1] % 2 == 0, '通常当たりにも切り替えられる')
resetState()
call(P('adminForce'), 1, nil)
nextTo = 'heso'
shoot(1)
nextTo = 'miss'
got = waitSpin(1)
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
rv = 0.5
clock = clock + 5000
call(P('sit'), 2, MID)
cash0 = money.CID2.cash
nextTo = 'heso'
local out = 0
for _ = 1, 4 do r = shoot(2); out = out + (r.cashOut or 0) end -- 25 玉借りて 4 発。届くたびに 3 玉ずつ戻る
nextTo = 'miss'
r = sync(2, 2000); out = out + (r.cashOut or 0)
ok(r.info.balls == 30 and out == 3 * PRICE and money.CID2.cash == cash0 - C.LendUnit * PRICE + out, '上限を超えた玉はその場で現金になる')
C.MaxBalls = maxBalls

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
clock = clock + 5000
nextTo = 'heso'
r = shoot(2)
nextTo = 'miss'
balls = r.info.balls + r.info.inflight
Arcade.flushDirty() -- 60 秒ごとの書き込み
ok(dataOf(MID).owner and dataOf(MID).owner.cid == 'CID2' and dataOf(MID).owner.balls == balls, '持ち玉（飛んでいる玉の賞球を含む）と持ち主が DB に控えられる')
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
r = sync(1, 2000)
balls = r.info.balls
cash0 = money.CID1.cash
handlers['QBCore:Server:OnPlayerUnload'](1)
ok(money.CID1.cash == cash0 + balls * PRICE, 'キャラクターを切り替えると精算される')
ok(machine().seat == nil and machine().data.owner == nil, '席が空き、持ち玉の控えも消える')
r = call(P('sit'), 1, MID)
ok(r.ok, '切り替えた後、また座れる')
shoot(1)
balls = sync(1, 2000).info.balls
cash0 = money.CID1.cash
pedPos[1] = FAR
r = shoot(1)
ok(not r.ok and r.left == true and r.yen == balls * PRICE and money.CID1.cash == cash0 + balls * PRICE, '台から離れて打とうとすると精算して席を空ける')
pedPos[1] = NEAR
call(P('sit'), 1, MID)
shoot(1)
balls = sync(1, 2000).info.balls
cash0 = money.CID1.cash
source = 1
handlers['playerDropped']()
ok(money.CID1.cash == cash0 + balls * PRICE and machine().seat == nil, '切断すると citizenid 宛てに精算される')

-- ===== 14. 壊れたデータ =====
local m = Arcade.newMachine({ id = 99, game = 'pachi', x = 0, y = 0, z = 0, heading = 0, setting = 1, data = '{["total"]="x",["history"]=5}' })
ok(m and m.data.total == 0 and type(m.data.history) == 'table' and m.data.kakuhen == 0, '壊れたデータは初期値で埋めて動かす')
m = Arcade.newMachine({ id = 98, game = 'pachi', x = 0, y = 0, z = 0, heading = 0, setting = 1, data = 'こわれた' })
ok(m and m.data.total == 0, 'JSON として読めないデータでも台は出る')

-- ===== 15. エンジン単体: 演出・図柄・保留の色 =====
local seq = {}
E.random = function() return table.remove(seq, 1) or 0.5 end
local function newData() return { total = 0, kakuhen = 0, normal = 0, since = 0, history = {} } end
local st, dd, evs = E.newState(), newData(), {}
st.queue[1] = { at = 0, via = 'heso', r = 0.0001, k = 0.9, hot = 'white' }
seq = { 0.5, 0.5, 0.5, 0.95 } -- スーパーリーチ・予告・図柄・ラウンドは振り分けの後ろ
E.advance(st, dd, 10, C, 1, nil, evs)
ok(st.spin.hit == 'normal' and st.spin.stage == 'sp' and st.spin.jp.rounds == C.Rounds.heso[#C.Rounds.heso][1], '通常当たり・スーパーリーチ・ラウンドは割合どおりに振り分ける')
ok(evs[1].duration == T.sp + T.hitTail and st.spin.jp.wins[1].open == st.spin.endAt + T.fanfare, '当たりの変動は長く、アタッカーが開く時刻が決まる')
st, evs = E.newState(), {}
st.queue[1] = { at = 0, via = 'heso', r = 0.9, k = 0.5, hot = 'white' }
seq = { 0.01, 0.5, 0.9 } -- ハズレ・リーチ・スーパーには進まない
E.advance(st, dd, 10, C, 1, nil, evs)
local g = st.spin.digits
ok(st.spin.hit == nil and st.spin.stage == 'reach' and g[1] == g[3] and g[2] ~= g[1] and evs[1].duration == T.reach, 'リーチハズレは左右が同じで中がずれる')
st, evs = E.newState(), {}
st.queue[1] = { at = 0, via = 'heso', r = 0.9, k = 0.5, hot = 'white' }
seq = { 0.01, 0.5, 0.01 }
E.advance(st, dd, 10, C, 1, nil, evs)
ok(st.spin.stage == 'sp' and st.spin.hit == nil and evs[1].duration == T.sp, 'ハズレでもスーパーリーチに進むことがある')
st, evs = E.newState(), {}
st.queue[1] = { at = 0, via = 'heso', r = 0.9, k = 0.5, hot = 'white' }
seq = { 0.9, 0.9 }
E.advance(st, dd, 10, C, 1, nil, evs)
g = st.spin.digits
ok(st.spin.hit == nil and st.spin.stage == 'none' and g[1] ~= g[3], 'ただのハズレは左右が揃わない')
st, evs = E.newState(), {}
st.flying[1] = { at = 5, to = 'heso', pay = 3 }
seq = { 0.9, 0.5, 0.01 } -- ハズレの保留だが、まれに色が変わる
local gained = E.advance(st, dd, 10, C, 1, nil, evs)
ok(gained == 3 and evs[1].hot == 'green', 'ハズレの保留も、まれに色が変わる（色だけでは決まらない）')

-- ===== 16. エンジン単体: アタッカーの開閉とオーバー入賞 =====
E.random = function() return 0.5 end
st = E.newState()
st.jackpot = { kind = 'kakuhen', rounds = 2, wins = { { open = 0, arr = {} } } }
local ft = 500
E.simulate = function(_, gates) return { to = gates.attacker(ft) and 'attacker' or 'miss', t = ft, path = {}, hits = {} } end
local tos = {}
for _ = 1, 8 do tos[#tos + 1] = E.shoot(st, 1000, C, 90).to end -- 1500 に届く 8 個
ft = 3000
tos[#tos + 1] = E.shoot(st, 1000, C, 90).to -- 9 個目は遅く届く（4000）。ここで閉じる
ok(st.jackpot.wins[1].close == 4000 and st.jackpot.wins[2].open == 4000 + T.roundGap, '9 個目が届く時刻に閉じ、次のラウンドが開く時刻が決まる')
ft = 1000
local over = E.shoot(st, 1000, C, 90).to -- 後から打ったが、閉じる前（2000）に届く
ft = 3500
local gap = E.shoot(st, 1000, C, 90).to -- 閉じた後、次が開く前（4500）に届く
ft = 4500
local nextRound = E.shoot(st, 1000, C, 90).to -- 次のラウンドが開いた後（5500）に届く
ok(over == 'attacker', '閉じる前に届いた玉は、数を超えていても入る（オーバー入賞）')
ok(gap == 'miss' and nextRound == 'attacker', 'ラウンドの間に届いた玉は入らず、次が開いた後の玉は入る')
local v = E.view(st, 2500, C).jackpot
ok(v.round == 1 and v.count == 9 and v.open == true, '画面には、その時刻までに届いた数が出る')
v = E.view(st, 4100, C).jackpot
ok(v.round == 1 and v.count == 10 and v.open == false, '閉じた後は閉じた表示になる')
v = E.view(st, 5600, C).jackpot
ok(v.round == 2 and v.count == 1 and v.open == true, '次のラウンドに進む')
dd = newData()
gained = E.advance(st, dd, 6000, C, 1, nil, nil)
ok(gained == 11 * C.Pay.attacker, '入った玉の賞球は、届いた時刻に入る')

-- ===== 17. 物理計算（本物）: 玉は盤面の中を動き、必ずどこかに着く =====
E.random = math.random
local B = PachiBoard
local okPath, counts = true, {}
for _, power in ipairs({ 0, 30, 30, 30, 60, 100, 100 }) do
  local res = realSimulate(power, { denchu = true, attacker = function() return true end })
  counts[res.to] = (counts[res.to] or 0) + 1
  if res.t <= 0 or res.t > PachiPhysics.MAX_TIME * 1000 + 1 or #res.path < 4 or #res.path % 2 ~= 0 then okPath = false end
  for i = 1, #res.path, 2 do
    local x, y = res.path[i] / 2, res.path[i + 1] / 2
    if (x - B.cx) ^ 2 + (y - B.cy) ^ 2 > (B.wall + 1) ^ 2 then okPath = false end
    if x > B.lcd.x + 1 and x < B.lcd.x + B.lcd.w - 1 and y > B.lcd.y + 1 and y < B.lcd.y + B.lcd.h - 1 then okPath = false end
  end
end
ok(okPath, '軌道は外レールの中にあり、液晶の中を通らない')
local known = true
for k in pairs(counts) do if not ({ miss = 1, heso = 1, denchu = 1, attacker = 1, general = 1 })[k] then known = false end end
ok(known, '行き先は miss / heso / denchu / attacker / general のどれか')
local right = 0
for _ = 1, 6 do if realSimulate(95, { denchu = false, attacker = function() return true end }).to == 'attacker' then right = right + 1 end end
ok(right >= 4, ('強く打つと右へ飛び、開いたアタッカーに入る（6 発中 %d 発）'):format(right))

-- ===== 18. 時計の折り返し =====
clock = 2147483000
local t1 = Arcade.now()
clock = -2147483648 + 352 -- 32 ビットの上限を越えて負に戻った（1000 ミリ秒後）
local t2 = Arcade.now()
ok(t2 - t1 == 1000, ('GetGameTimer が負に折り返しても、時刻は続きから進む（差 %s）'):format(tostring(t2 - t1)))
clock = clock + 500
ok(Arcade.now() - t2 == 500, '折り返した後も普段どおり進む')

print(('結果: %d 件 OK、%d 件 NG'):format(pass, fail))
if fail > 0 then error('テスト失敗') end
