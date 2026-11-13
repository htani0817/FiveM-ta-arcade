-- 盤面（shared/pachi_board.lua）の釘の並びで、ハンドルの強さごとに玉がどこへ行くかを測る
-- node lua-run.js pachi-board.lua [強さごとの玉数（既定 400）] [normal / support / jackpot / all（既定 all）] [強さの刻み（既定 5）]
--   normal: 通常時（電チューもアタッカーも閉じている）、support: 確変・時短中（電チューが開く）、jackpot: 大当たり中（アタッカーが開く）
local function src(name)
  local f, err = load((SOURCES[name]:gsub('`[%w_]+`', '0')), name)
  if not f then error(err) end
  return f
end
src('shared/pachi_board.lua')()
src('server/pachi_physics.lua')()
local P = PachiPhysics

local n = tonumber(ARGS[1]) or 400
local which = ARGS[2] or 'all'
local stepP = tonumber(ARGS[3]) or 5

local GATES = {
  normal = { denchu = false, attacker = function() return false end },
  support = { denchu = true, attacker = function() return false end },
  jackpot = { denchu = false, attacker = function() return true end },
}

local function run(cond, p0, p1)
  print(('--- %s（強さごとに %d 玉）---'):format(cond, n))
  print('強さ | ヘソ | 一般 | 電チュー | アタッカー | 平均の時間 | 最長 | 時間切れ')
  for power = p0, p1, stepP do
    local c = { miss = 0, heso = 0, general = 0, denchu = 0, attacker = 0 }
    local tsum, tmax, late = 0, 0, 0
    for _ = 1, n do
      local r = P.simulate(power, math.random, GATES[cond])
      c[r.to] = c[r.to] + 1
      tsum = tsum + r.t
      if r.t > tmax then tmax = r.t end
      if r.t >= P.MAX_TIME * 1000 - 5 then late = late + 1 end
    end
    print(('%4d | %5.1f%% | %5.1f%% | %5.1f%% | %5.1f%% | %5.2f秒 | %4.1f秒 | %d'):format(
      power, c.heso / n * 100, c.general / n * 100, c.denchu / n * 100, c.attacker / n * 100, tsum / n / 1000, tmax / 1000, late))
  end
end

if which == 'all' or which == 'normal' then run('normal', 0, 100) end
if which == 'all' or which == 'support' then run('support', 60, 100) end
if which == 'all' or which == 'jackpot' then run('jackpot', 60, 100) end
