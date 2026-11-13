// 入賞の割合を、物理計算の JavaScript 版（Lua 版と同じ軌道になる。pachi-physics-check.js で確かめる）で速く測る
// node pachi-rates.js [強さごとの玉数（既定 4000）]            … 強さごとの表を出す
// node pachi-rates.js 40000 rtp                                … 払い出し率の計算（pachi-rtp.lua）に渡す数字を 1 行で出す
// node pachi-rates.js 6000 gap 15.4 15.8 16.2                  … 命釘の間隔を変えたときの、いちばん回る強さとヘソの割合
const { load } = require('./pachi-physics');
const sim = load();
const n = +process.argv[2] || 4000;
const mode = process.argv[3] || 'table';
const RIGHT = 92;

const GATES = {
  normal: { denchu: false, attacker: () => false },
  support: { denchu: true, attacker: () => false },
  jackpot: { denchu: false, attacker: () => true },
};
function shots(cond, power, count) {
  const c = { miss: 0, heso: 0, general: 0, denchu: 0, attacker: 0, t: 0, late: 0 };
  for (let i = 0; i < count; i++) {
    const r = sim.simulate(power, Math.random, GATES[cond]);
    c[r.to]++;
    c.t += r.t;
    if (r.t >= sim.P.MAX_TIME * 1000 - 5) c.late++;
  }
  for (const k of ['miss', 'heso', 'general', 'denchu', 'attacker']) c[k] /= count;
  c.t /= count;
  return c;
}
const pct = (v) => (v * 100).toFixed(2).padStart(6) + '%';

// いちばんヘソに入る強さ（左打ちの範囲で探す）。探したときの数字は良い方へ偏るので、決めた強さで測り直す
function bestLeft(count) {
  let best = 0, rate = -1;
  for (let p = 0; p <= 70; p += 2) {
    const c = shots('normal', p, Math.ceil(count / 4));
    if (c.heso > rate) { best = p; rate = c.heso; }
  }
  // 山の近くを 1 刻みで見直す
  let fine = best, fineRate = -1;
  for (let p = Math.max(0, best - 3); p <= best + 3; p++) {
    const c = shots('normal', p, count);
    if (c.heso > fineRate) { fine = p; fineRate = c.heso; }
  }
  return { power: fine, c: shots('normal', fine, count * 2) };
}

if (mode === 'rtp') {
  const b = bestLeft(n);
  const sup = shots('support', RIGHT, n), jp = shots('jackpot', RIGHT, n);
  // best heso general tLeft | denchu hesoRight tSupport | attacker tJackpot
  console.log([b.power, b.c.heso, b.c.general, b.c.t, sup.denchu, sup.heso, sup.t, jp.attacker, jp.t].map((v) => +v.toFixed(5)).join(' '));
} else if (mode === 'gap') {
  const B = sim.B;
  const li = B.nails.findIndex((q) => q.y === 358 && q.x < B.pocket.heso.x), ri = B.nails.findIndex((q) => q.y === 358 && q.x > B.pocket.heso.x);
  for (const gap of process.argv.slice(4).map(Number)) {
    B.nails[li].x = B.pocket.heso.x - gap / 2 - B.nailR;
    B.nails[ri].x = B.pocket.heso.x + gap / 2 + B.nailR;
    sim.build();
    const b = bestLeft(n);
    console.log(`命釘の間隔 ${gap.toFixed(1)}: いちばん回る強さ ${b.power}  ヘソ ${pct(b.c.heso)}（${(1 / b.c.heso).toFixed(1)} 玉に 1 回）  一般 ${pct(b.c.general)}`);
  }
} else {
  console.log(`通常時（強さごとに ${n} 玉）`);
  console.log('強さ |   ヘソ  |   一般  | 平均の時間 | 時間切れ');
  for (let p = 0; p <= 100; p += 4) {
    const c = shots('normal', p, n);
    console.log(`${String(p).padStart(4)} | ${pct(c.heso)} | ${pct(c.general)} | ${(c.t / 1000).toFixed(2)}秒 | ${c.late}`);
  }
  console.log(`右打ち（強さごとに ${n} 玉）`);
  console.log('強さ | 確変・時短中の電チュー | 大当たり中のアタッカー');
  for (let p = 72; p <= 100; p += 4) {
    console.log(`${String(p).padStart(4)} | ${pct(shots('support', p, n).denchu)} | ${pct(shots('jackpot', p, n).attacker)}`);
  }
}
