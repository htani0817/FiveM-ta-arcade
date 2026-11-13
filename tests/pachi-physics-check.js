// 物理計算の JavaScript 版（tests/pachi-physics.js）が、Lua 版（server/pachi_physics.lua）とまったく同じ軌道を出すことを確かめる
// 同じ並びの乱数で同じ玉を打ち、行き先・時間・軌道の全部の点・釘に当たった点を比べる
// node pachi-physics-check.js [玉数（既定 30）]
const path = require('path');
const { execFileSync } = require('child_process');
const { load, lcg } = require('./pachi-physics');

const n = +process.argv[2] || 30;
const lua = JSON.parse(execFileSync(process.execPath, [path.join(__dirname, 'lua-run.js'), path.join(__dirname, 'pachi-export.lua'), 'det', String(n)],
  { cwd: __dirname, encoding: 'utf8', env: process.env, maxBuffer: 1 << 28 }));
const sim = load();
const GATES = {
  normal: { denchu: false, attacker: () => false },
  support: { denchu: true, attacker: () => false },
  jackpot: { denchu: false, attacker: () => true },
};
const conds = ['normal', 'support', 'jackpot'];
let bad = 0, points = 0;
const count = {};
for (let i = 1; i <= n; i++) {
  const r = sim.simulate((i * 7) % 101, lcg(1000 + i), GATES[conds[i % 3]]);
  const want = lua[i - 1];
  count[r.to] = (count[r.to] || 0) + 1;
  points += r.path.length / 2;
  const same = r.to === want.to && r.t === want.t && JSON.stringify(r.path) === JSON.stringify(want.path) && JSON.stringify(r.hits) === JSON.stringify(want.hits);
  if (!same) { bad++; console.log(`NG: ${i} 個目（強さ ${(i * 7) % 101}・${conds[i % 3]}） Lua ${want.to} ${want.t}ms ${want.path.length / 2}点 / JS ${r.to} ${r.t}ms ${r.path.length / 2}点`); }
}
console.log(`${n} 玉・軌道 ${points} 点を比べた。行き先: ${JSON.stringify(count)}`);
console.log(bad ? `${bad} 玉が Lua 版と違います` : 'Lua 版とまったく同じ');
process.exit(bad ? 1 : 0);
