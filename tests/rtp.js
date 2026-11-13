// 払い出し率の計算。config.lua の抽選値と engine.lua のリールで、ゲームを大量に回す
// node rtp.js [ゲーム数]
// 「適当押し」= 押す位置がばらばら、「目押し」= 毎回いちばん良い位置を押す（取りこぼしなし）
const fs = require('fs'), path = require('path');
const { N, LINES, COMBOS, make, readReels } = require('./engine-js');
const root = path.join(__dirname, '..');
const reels = readReels(fs.readFileSync(path.join(root, 'shared/slot_engine.lua'), 'utf8'));
const cfg = fs.readFileSync(path.join(root, 'config.lua'), 'utf8');
const lot = {};
for (const m of cfg.matchAll(/\[(\d)\] = \{ ([^}]+) \}/g)) {
  lot[m[1]] = Object.fromEntries(m[2].split(',').map((kv) => kv.trim().split(' = ')).map(([k, v]) => [k, +v]));
}
const num = (re) => +cfg.match(re)[1];
const BIG_END = num(/big = \{ endPay = (\d+)/), REG_END = num(/reg = \{ endPay = (\d+)/);
const BELL_CH = num(/bellChance = ([\d.]+)/);
const PAY = { bell: 8, suika: 6, cherry: 2 };
const eng = make(reels);
const ORDERS = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]];

function evalPay(want, pos, bonus) {
  let pay = 0, got = null;
  for (const line of LINES) {
    const s = line.map((row, r) => reels[r][(pos[r] + (3 - row)) % N]);
    const c = COMBOS[want];
    if (c && c.every((x, i) => x === '*' || x === s[i])) { got = want; pay += want === 'bell' && bonus ? 15 : (PAY[want] || 0); }
  }
  return [Math.min(15, pay), got];
}
function play(want, perfect, bonus) {
  const order = ORDERS[Math.floor(Math.random() * 6)];
  if (!perfect || !want) {
    const st = [null, null, null];
    for (const r of order) st[r] = eng.decide(want || 'none', st, r, Math.floor(Math.random() * N));
    return evalPay(want, st, bonus);
  }
  // 目押し: 3 本とも全部の位置を試して、いちばん払い出しが多い止め方
  let best = [0, null];
  for (let a = 0; a < N; a++) for (let b = 0; b < N; b++) for (let c = 0; c < N; c += 1) {
    const st = [null, null, null]; const pr = [a, b, c];
    for (const r of [0, 1, 2]) st[r] = eng.decide(want, st, r, pr[r]);
    const res = evalPay(want, st, bonus);
    if (res[1] && res[0] >= best[0]) { best = res; if (want === 'big' || want === 'reg' || want === 'replay') return best; }
  }
  return best;
}
const memoPerfect = {};
function playCached(want, perfect, bonus) {
  if (!perfect || !want) return play(want, false, bonus);
  const k = want + bonus;
  if (!(k in memoPerfect)) memoPerfect[k] = play(want, true, bonus);
  return memoPerfect[k];
}

function draw(t) {
  const r = Math.random(); let acc = 0;
  for (const k of ['replay', 'bell', 'suika', 'cherry', 'big', 'reg', 'big_cherry', 'reg_cherry']) { acc += 1 / t[k]; if (r < acc) return k; }
  return null;
}

function sim(setting, games, perfect) {
  const t = lot[setting];
  let inM = 0, outM = 0, mode = 'normal', bonusPay = 0, carried = null, replay = false, big = 0, reg = 0, normalGames = 0;
  for (let g = 0; g < games; g++) {
    if (mode === 'normal' && replay) replay = false; else inM += 3;
    let want;
    if (mode !== 'normal') want = Math.random() < BELL_CH ? 'bell' : null;
    else {
      normalGames++;
      const f = draw(t);
      let small = null, bonus = null;
      if (f === 'big_cherry') { small = 'cherry'; bonus = 'big'; } else if (f === 'reg_cherry') { small = 'cherry'; bonus = 'reg'; }
      else if (f === 'big' || f === 'reg') bonus = f; else small = f;
      if (bonus && !carried) carried = bonus;
      want = small || carried;
    }
    const [pay, got] = playCached(want, perfect, mode !== 'normal');
    outM += pay;
    if (mode !== 'normal') {
      bonusPay += pay;
      if (bonusPay >= (mode === 'big' ? BIG_END : REG_END)) { mode = 'normal'; bonusPay = 0; }
    } else {
      if (got === 'big' || got === 'reg') { mode = got; bonusPay = 0; carried = null; if (got === 'big') big++; else reg++; }
      replay = got === 'replay';
    }
  }
  return { rtp: outM / inM, big: normalGames / big, reg: normalGames / reg, perGame: (outM - inM) / games };
}
const games = +(process.argv[2] || 2000000);
console.log(`設定 | 適当押し 払い出し率 | 目押し 払い出し率 | BIG 確率 | REG 確率 | 1時間(600G)の収支の目安 適当/目押し（100円/枚）`);
for (const s of Object.keys(lot)) {
  const a = sim(s, games, false), b = sim(s, games, true);
  console.log(`${s} | ${(a.rtp * 100).toFixed(1)}% | ${(b.rtp * 100).toFixed(1)}% | 1/${b.big.toFixed(0)} | 1/${b.reg.toFixed(0)} | ${Math.round(a.perGame * 600 * 100).toLocaleString()}円 / ${Math.round(b.perGame * 600 * 100).toLocaleString()}円`);
}
