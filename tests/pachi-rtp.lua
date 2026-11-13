-- パチンコの払い出し率の計算。エンジンと config.lua の数字をそのまま使う
-- ふつうは node pachi-rtp.js [玉数] [check] から呼ぶ（入賞の割合を物理計算で測ってから、ここへ渡してくる）
--
-- 3 段階で出す。
--   1. 物理計算で玉を打ち、入賞の割合を測る（tests/pachi-rates.js。左打ちはいちばん回るハンドルの強さを探す。右打ちは強さ 92）
--   2. その割合どおりに行き先を決める代わりの計算で、長い時間を打ちっぱなしにして、ぶれの小さい数字を測る
--      （1 回転あたりの玉数、玉 1 個あたりの賞球、大当たり 1 回で打つ玉数と賞球）
--   3. 連チャンの回数は式で出す（大当たりは回数が少なく、打つだけでは設定ごとの差が乱数のぶれに埋もれる）
-- check を付けると、2 の計算を設定ごとに長く回した結果も並べる（式と大きくずれていないかを見るため）
--
-- 打ち方は「通常時は左打ち（いちばん回る強さ）、大当たり中と確変・時短中は右打ち」。切り替えの遅れは入れていない
-- 引数: <左の強さ> <ヘソ> <一般> <左の時間> <電チュー> <右のヘソ> <確変中の時間> <アタッカー> <大当たり中の時間> [check]
local function src(name)
  local f, err = load((SOURCES[name]:gsub('`[%w_]+`', '0')), name)
  if not f then error(err) end
  return f
end
function vec3(x, y, z) return { x = x, y = y, z = z } end
src('config.lua')()
src('server/pachi_engine.lua')()
local E, C = PachiEngine, Config.Pachi
local T = C.Time

local check = ARGS[10] == 'check'
-- 乱数の種は決めない（fengari で math.randomseed を呼ぶと乱数が偏る。2026-11-13 に確認）

local PER_HOUR = 3600000 // C.ShotInterval
local RIGHT = 92
local function yen(n)
  local man = math.floor(math.abs(n) * C.BallPrice / 10000 + 0.5)
  local s = tostring(man):reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
  return (n < 0 and '-' or '+') .. s .. '万円'
end
local function newData() return { total = 0, kakuhen = 0, normal = 0, since = 0, history = {} } end

---------------------------------------------------------------------------
-- 1. 物理計算で測った入賞の割合（tests/pachi-rates.js が測って渡してくる）
---------------------------------------------------------------------------
local function arg(i) return tonumber(ARGS[i]) or error('引数が足りません。node pachi-rtp.js から呼んでください') end
local best = arg(1)
local left = { heso = arg(2), general = arg(3), t = arg(4) }
local sup = { denchu = arg(5), heso = arg(6), t = arg(7) }
local jpk = { attacker = arg(8), t = arg(9) }
print('1. 物理計算で測った入賞の割合')
print(('  左打ち（いちばん回る強さ %d）  ヘソ %.2f%%（%.1f 玉に 1 回）、一般入賞口 %.2f%%、届くまで平均 %.2f秒'):format(best, left.heso * 100, 1 / left.heso, left.general * 100, left.t / 1000))
print(('  右打ち・確変と時短中  電チュー %.1f%%、ヘソ %.2f%%、届くまで平均 %.2f秒'):format(sup.denchu * 100, sup.heso * 100, sup.t / 1000))
print(('  右打ち・大当たり中    アタッカー %.1f%%、届くまで平均 %.2f秒'):format(jpk.attacker * 100, jpk.t / 1000))

---------------------------------------------------------------------------
-- 2. 測った割合どおりに行き先を決めて、長い時間を回す
---------------------------------------------------------------------------
local function fakeSimulate(power, gates)
  local u = math.random()
  if power >= 78 then
    -- 右打ち。アタッカーが開く時刻に届くなら、まずアタッカー。次に電チュー
    if u < jpk.attacker and gates.attacker(jpk.t) then return { to = 'attacker', t = jpk.t } end
    if gates.denchu and u < sup.denchu then return { to = 'denchu', t = sup.t } end
    if u > 1 - sup.heso then return { to = 'heso', t = sup.t } end
    return { to = 'miss', t = sup.t }
  end
  if u < left.heso then return { to = 'heso', t = left.t } end
  if u < left.heso + left.general then return { to = 'general', t = left.t } end
  return { to = 'miss', t = left.t }
end
E.simulate = fakeSimulate

local function measure(n, setting)
  -- 時刻は小数で持つ（fengari の整数は 32 ビットなので、ミリ秒を整数で足していくと約 358万玉で桁あふれする）
  local st, d, now = E.newState(), newData(), 0.0
  local m = { normal = { balls = 0, pay = 0, spins = 0 }, support = { balls = 0, pay = 0, spins = 0 }, jp = {}, paid = 0 }
  local lastJp = nil
  for _ = 1, n do
    now = now + C.ShotInterval
    local before, total0 = (st.mode == 'normal') and 'normal' or 'support', d.total
    local gained = E.advance(st, d, now, C, setting, nil, nil)
    m[before].spins = m[before].spins + (d.total - total0)
    m.paid = m.paid + gained
    local jp = st.jackpot
    local phase
    if jp then
      m.jp[jp.rounds] = m.jp[jp.rounds] or { balls = 0, count = 0, pay = 0 }
      if jp ~= lastJp then lastJp = jp; m.jp[jp.rounds].count = m.jp[jp.rounds].count + 1 end
      phase = m.jp[jp.rounds]
    else
      phase = m[(st.mode == 'normal') and 'normal' or 'support']
    end
    -- 打ち方: 大当たり中と確変・時短中は右、通常時は左
    local right = jp ~= nil or st.mode ~= 'normal'
    local _, pay = E.shoot(st, now, C, right and RIGHT or best)
    phase.balls = phase.balls + 1
    phase.pay = phase.pay + pay -- 打った時点の状態に、その玉の賞球を数える
  end
  return m
end

local balls = 3000000
local m = measure(balls, 1)
local bn, rn = m.normal.balls / m.normal.spins, m.normal.pay / m.normal.balls
local bs, rs = m.support.balls / m.support.spins, m.support.pay / m.support.balls
print('')
print(('2. 測った割合で %d 玉を打ちっぱなし'):format(balls))
print(('  通常時        1回転に %.2f 玉、玉1個の賞球 %.3f 玉'):format(bn, rn))
print(('  確変・時短中  1回転に %.2f 玉、玉1個の賞球 %.3f 玉'):format(bs, rs))
local jpBalls, jpPay = {}, {}
for r, x in pairs(m.jp) do
  jpBalls[r], jpPay[r] = x.balls / x.count, x.pay / x.count
  print(('  %2dR の大当たり 打つ玉 %.1f 玉、賞球 %.0f 玉（差し引き +%.0f 玉）'):format(r, jpBalls[r], jpPay[r], jpPay[r] - jpBalls[r]))
end

local function avgJackpot(list)
  local b, p = 0, 0
  for _, e in ipairs(list) do
    local r, w = e[1], e[2]
    local per = C.RoundCount / jpk.attacker
    b = b + w * (jpBalls[r] or (r * per + T.fanfare / C.ShotInterval))
    p = p + w * (jpPay[r] or (r * C.RoundCount * C.Pay.attacker))
  end
  return b, p
end
local b1, p1 = avgJackpot(C.Rounds.heso)
local b2, p2 = avgJackpot(C.Rounds.denchu)

---------------------------------------------------------------------------
-- 3. 式で出す
---------------------------------------------------------------------------
print('')
print(('3. 1玉 %d円、%d ミリ秒に1発（1時間に %d 発）'):format(C.BallPrice, C.ShotInterval, PER_HOUR))
-- 大当たり確率 1/n のときの数字を式で出す
local function formula(n)
  local p, ph, k, J = 1.0 / n, 1.0 / C.HighChance, C.KakuhenRate, C.JitanSpins
  local regain = 1 - (1 - p) ^ J     -- 時短中に引き戻す割合
  local jitanSpins = regain / p      -- 時短 1 回で回る回転数の平均
  local cont = k + (1 - k) * regain  -- 大当たりの後、通常に戻る前にもう一度当たる割合
  local hits = 1 / (1 - cont)        -- 初当たり 1 回あたりの大当たりの回数
  local nBalls = bn / p
  local sBalls = bs * hits * (k / ph + (1 - k) * jitanSpins)
  local jBalls = b1 + (hits - 1) * b2
  local jPay = p1 + (hits - 1) * p2
  local total = nBalls + sBalls + jBalls
  local paid = nBalls * rn + sBalls * rs + jPay
  return { rtp = paid / total, hits = hits, lose = nBalls * (1 - rn), win = jPay - jBalls - sBalls * (1 - rs) }
end

print('設定 | 大当たり | 払い出し率 | 連チャンの平均 | 初当たりまでの平均 | 初当たり1回の出玉の平均 | 1時間の収支')
local expected = {}
for setting = 1, 6 do
  local f = formula(C.HitChance[setting])
  expected[setting] = f.rtp
  print(('  %d  |  1/%d  |  %6.2f%%  |  %.2f 回  |  %s  |  %s  |  %s'):format(
    setting, C.HitChance[setting], f.rtp * 100, f.hits, yen(-f.lose), yen(f.win), yen((f.rtp - 1) * PER_HOUR)))
end

-- 目標の払い出し率に合う大当たり確率（config.lua の HitChance を決めるときの目安）
local line = {}
for _, target in ipairs({ 0.920, 0.945, 0.973, 1.003, 1.030, 1.059 }) do
  local lo, hi = 50, 2000 -- 分母が大きいほど払い出し率は下がる
  for _ = 1, 40 do
    local mid = (lo + hi) / 2
    if formula(mid).rtp > target then lo = mid else hi = mid end
  end
  line[#line + 1] = ('%.1f%% → 1/%d'):format(target * 100, math.floor(lo + 0.5))
end
print('目標に合う大当たり確率: ' .. table.concat(line, '、'))

if check then
  print('')
  print(('打ちっぱなし（設定ごとに %d 玉。乱数のぶれが大きい）'):format(balls * 2))
  for setting = 1, 6 do
    local x = measure(balls * 2, setting)
    print(('  %d  |  %6.2f%%（式は %6.2f%%）'):format(setting, x.paid / (balls * 2) * 100, expected[setting] * 100))
  end
end
