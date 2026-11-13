-- パチンコの払い出し率の計算。config.lua の数字と server/pachi_engine.lua をそのまま使う
-- node lua-run.js pachi-rtp.lua [実測に使う玉数（既定 300万）] [check]
--
-- 大当たりは回数が少なく、玉を打つだけの計算では設定ごとの差が乱数のぶれに埋もれる（400万玉でも ±5% ほど動く）。
-- そこで、ぶれの小さい数字だけをエンジンを動かして測り、連チャンの回数は式で出す。
--   測るもの: 通常時と確変・時短中の「1回転あたりの玉数」「玉1個あたりの賞球」、大当たり1回で打つ玉数
--   式で出すもの: 初当たりまでの回転数、時短中に引き戻す割合、連チャンの回数
-- check を付けると、最後に打ちっぱなしの結果も並べる（式と大きくずれていないかを見るため。遅い）
local function src(name)
  local f, err = load((SOURCES[name]:gsub('`[%w_]+`', '0')), name)
  if not f then error(err) end
  return f
end
function vec3(x, y, z) return { x = x, y = y, z = z } end
src('config.lua')()
src('server/pachi_engine.lua')()
local E, C = PachiEngine, Config.Pachi

local balls = tonumber(ARGS[1]) or 3000000
local check = ARGS[2] == 'check'
-- 乱数の種は決めない（fengari で math.randomseed を呼ぶと乱数が偏り、払い出し率が半分ほどに出る。2026-11-13 に確認）

local PER_HOUR = 3600000 // C.ShotInterval
local function yen(n)
  local man = math.floor(math.abs(n) * C.BallPrice / 10000 + 0.5)
  local s = tostring(man):reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
  return (n < 0 and '-' or '+') .. s .. '万円'
end
local function newData() return { total = 0, kakuhen = 0, normal = 0, since = 0, history = {} } end

-- ---- 1. 測る ----
-- 状態ごとに、打った玉・賞球・回転数を数える。大当たりはラウンド数ごとに打った玉を数える
local function measure(n, setting)
  -- 時刻は小数で持つ（fengari の整数は 32 ビットなので、ミリ秒を整数で足していくと約 358万玉で桁あふれして変動が止まる）
  local st, d, now = E.newState(), newData(), 0.0
  local m = { normal = { balls = 0, pay = 0, spins = 0 }, support = { balls = 0, pay = 0, spins = 0 }, jp = {}, paid = 0 }
  local rounds = nil
  for _ = 1, n do
    now = now + C.ShotInterval
    local before, total0 = (st.mode == 'normal') and 'normal' or 'support', d.total
    E.advance(st, d, now, C, setting, nil, nil)
    m[before].spins = m[before].spins + (d.total - total0)
    local phase
    if st.jackpot then
      rounds = st.jackpot.rounds
      m.jp[rounds] = m.jp[rounds] or { balls = 0, count = 0, pay = 0 }
      if st.jackpot.round == 1 and st.jackpot.count == 0 and not st.jackpot.seen then
        st.jackpot.seen = true
        m.jp[rounds].count = m.jp[rounds].count + 1
      end
      phase = m.jp[rounds]
    else
      phase = m[(st.mode == 'normal') and 'normal' or 'support']
    end
    local _, pay = E.shoot(st, now, C, nil)
    phase.balls = phase.balls + 1
    phase.pay = phase.pay + pay
    m.paid = m.paid + pay
  end
  return m, d
end

local m = measure(balls, 1)
local bn, rn = m.normal.balls / m.normal.spins, m.normal.pay / m.normal.balls
local bs, rs = m.support.balls / m.support.spins, m.support.pay / m.support.balls
print(('実測（%d 玉）'):format(balls))
print(('  通常時        1回転に %.2f 玉、玉1個の賞球 %.3f 玉'):format(bn, rn))
print(('  確変・時短中  1回転に %.2f 玉、玉1個の賞球 %.3f 玉'):format(bs, rs))
local jpBalls, jpPay = {}, {}
for r, x in pairs(m.jp) do
  jpBalls[r], jpPay[r] = x.balls / x.count, x.pay / x.count
  print(('  %2dR の大当たり 打つ玉 %.1f 玉、賞球 %.0f 玉（差し引き +%.0f 玉）'):format(r, jpBalls[r], jpPay[r], jpPay[r] - jpBalls[r]))
end

-- ラウンドの振り分けの平均（打つ玉・賞球）
local function avgJackpot(list)
  local b, p = 0, 0
  for _, e in ipairs(list) do
    local r, w = e[1], e[2]
    -- 実測に出てこなかったラウンド数は、1ラウンドの玉数から見積もる
    local per = C.RoundCount / C.Entry.attacker
    b = b + w * (jpBalls[r] or (r * per + C.Time.fanfare / C.ShotInterval))
    p = p + w * (jpPay[r] or (r * C.RoundCount * C.Pay.attacker))
  end
  return b, p
end
local b1, p1 = avgJackpot(C.Rounds.heso)
local b2, p2 = avgJackpot(C.Rounds.denchu)

-- ---- 2. 式で出す ----
print('')
print(('1玉 %d円、%d ミリ秒に1発（1時間に %d 発）。打ちっぱなしの場合'):format(C.BallPrice, C.ShotInterval, PER_HOUR))
print('設定 | 大当たり | 払い出し率 | 連チャンの平均 | 初当たりまでの平均 | 初当たり1回の出玉の平均 | 1時間の収支')
local expected = {}
for setting = 1, 6 do
  local p, ph, k, J = 1.0 / C.HitChance[setting], 1.0 / C.HighChance, C.KakuhenRate, C.JitanSpins
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
  local rtp = paid / total
  expected[setting] = rtp
  print(('  %d  |  1/%d  |  %6.2f%%  |  %.2f 回  |  %s  |  %s  |  %s'):format(
    setting, C.HitChance[setting], rtp * 100, hits, yen(-nBalls * (1 - rn)),
    yen(jPay - jBalls - sBalls * (1 - rs)), yen((rtp - 1) * PER_HOUR)))
end

-- ---- 3. 打ちっぱなしと比べる ----
if check then
  print('')
  print(('打ちっぱなし（設定ごとに %d 玉。乱数のぶれが大きい）'):format(balls * 4))
  for setting = 1, 6 do
    local x = measure(balls * 4, setting)
    print(('  %d  |  %6.2f%%（式は %6.2f%%）'):format(setting, x.paid / (balls * 4) * 100, expected[setting] * 100))
  end
end
