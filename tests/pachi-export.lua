-- 盤面（shared/pachi_board.lua）と、物理計算で出した玉の軌道の見本を JSON で出す
-- node lua-run.js pachi-export.lua board   > ../blender/tex/pachi_board.json   （テクスチャ用。盤面だけ）
-- node lua-run.js pachi-export.lua sample  > ../design/pachi_sample.js         （画面の見本 ?preview&pachi 用。盤面と軌道）
-- node lua-run.js pachi-export.lua paths 40 55 > 軌道だけ（釘を直すときに絵にして見る用。強さ 40 から 55 まで）
-- node lua-run.js pachi-export.lua exact  … 盤面を桁を落とさずに出す（tests/pachi-physics.js が読む）
-- node lua-run.js pachi-export.lua det 30 … 決まった乱数で 30 玉の軌道を出す（tests/pachi-physics-check.js が JavaScript 版と比べる）
local function src(name)
  local f, err = load((SOURCES[name]:gsub('`[%w_]+`', '0')), name)
  if not f then error(err) end
  return f
end
src('shared/pachi_board.lua')()
src('server/pachi_physics.lua')()
local P, B = PachiPhysics, PachiBoard

local function ser(v)
  local t = type(v)
  if t == 'table' then
    if #v > 0 or next(v) == nil then
      local p = {}
      for i = 1, #v do p[i] = ser(v[i]) end
      return '[' .. table.concat(p, ',') .. ']'
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys)
    local p = {}
    for _, k in ipairs(keys) do p[#p + 1] = '"' .. k .. '":' .. ser(v[k]) end
    return '{' .. table.concat(p, ',') .. '}'
  elseif t == 'string' then
    return '"' .. v .. '"'
  elseif t == 'number' then
    if v == math.floor(v) then return ('%d'):format(v) end
    return (EXACT and '%.17g' or '%.2f'):format(v)
  end
  return tostring(v)
end

local GATES = {
  normal = { denchu = false, attacker = function() return false end },
  support = { denchu = true, attacker = function() return false end },
  jackpot = { denchu = false, attacker = function() return true end },
}
local function shots(cond, powers, each)
  local out = {}
  for _, power in ipairs(powers) do
    for _ = 1, each do
      local r = P.simulate(power, math.random, GATES[cond])
      out[#out + 1] = { power = power, to = r.to, t = r.t, path = r.path, hits = r.hits }
    end
  end
  return out
end

local mode = ARGS[1] or 'board'
if mode == 'exact' then
  EXACT = true
  print(ser(B.export()))
elseif mode == 'det' then
  -- Lua と JavaScript で同じ並びになる乱数（tests/pachi-physics.js の lcg と同じ式。小数で持つ）
  local function lcg(seed)
    local s = seed + 0.0
    return function() s = (s * 48271.0) % 2147483647.0; return s / 2147483647.0 end
  end
  local conds = { 'normal', 'support', 'jackpot' }
  local out = {}
  for i = 1, tonumber(ARGS[2]) or 30 do
    local r = P.simulate((i * 7) % 101, lcg(1000 + i), GATES[conds[i % 3 + 1]])
    out[#out + 1] = { to = r.to, t = r.t, path = r.path, hits = r.hits }
  end
  print(ser(out))
elseif mode == 'board' then
  print(ser(B.export()))
elseif mode == 'paths' then
  local p0, p1 = tonumber(ARGS[2]) or 40, tonumber(ARGS[3]) or 55
  local powers = {}
  for p = p0, p1 do powers[#powers + 1] = p end
  print(ser({ board = B.export(), shots = shots(ARGS[4] or 'normal', powers, tonumber(ARGS[5]) or 6) }))
else
  local left, right = {}, {}
  for p = 20, 60, 4 do left[#left + 1] = p end
  for p = 84, 100, 4 do right[#right + 1] = p end
  local all = {}
  for p = 0, 100, 10 do all[#all + 1] = p end
  print('// tests/pachi-export.lua が作る。台の画面の見本（html/index.html?preview&pachi）だけが読む。リソースには入れない')
  print('window.PACHI_SAMPLE = ' .. ser({
    board = B.export(),
    normal = shots('normal', all, 10),
    support = shots('support', right, 24),
    jackpot = shots('jackpot', right, 24),
    aim = shots('normal', left, 14),
  }) .. ';')
end
