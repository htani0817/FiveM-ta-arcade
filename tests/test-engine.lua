-- リール制御の総当たり検査: 全ての役 × 全ての押し順 × 全ての押し位置
-- 1) 当たっていない役が揃うことが一度もない 2) 狙う役がどれだけ揃うか（取りこぼし率）
load(SOURCES['shared/slot_engine.lua'])()
local E = SlotEngine
local orders = { {1,2,3}, {1,3,2}, {2,1,3}, {2,3,1}, {3,1,2}, {3,2,1} }
local wants = { false, 'replay', 'bell', 'suika', 'cherry', 'big', 'reg' }
local step = tonumber(ARGS[1] or '1')
local fails = 0
for _, want in ipairs(wants) do
  local w = want or nil
  local total, hit, bad = 0, 0, 0
  local t0 = os.clock()
  for _, o in ipairs(orders) do
    for a = 0, 20, step do for b = 0, 20, step do for c = 0, 20, step do
      local pr = { a, b, c }
      local presses = {}
      for i = 1, 3 do presses[i] = { reel = o[i], press = pr[o[i]] } end
      local pos = E.resolve(w, presses)
      local nbad, nhit = 0, false
      for _, h in ipairs(E.evaluate(pos)) do
        if h.combo == w then nhit = true else nbad = nbad + 1 end
      end
      total = total + 1
      if nbad > 0 then bad = bad + 1 end
      if nhit then hit = hit + 1 end
    end end end
  end
  print(('%-7s 回数 %6d  揃った %6.2f%%  揃ってはいけない役 %d 回  (%.1f秒)'):format(
    tostring(want or 'ハズレ'), total, hit / total * 100, bad, os.clock() - t0))
  if bad > 0 then fails = fails + 1 end
end
print(fails == 0 and 'OK' or ('NG ' .. fails))
