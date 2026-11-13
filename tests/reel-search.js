// engine.lua と同じ制御を JS で動かし、リール配列を入れ替えながら良い並びを探す（開発用）
// node reel-search.js [回数]
const N = 21, SLIP = 4;
const LINES = [[2,2,2],[1,1,1],[3,3,3],[1,2,3],[3,2,1]];
const COMBOS = { replay:['RP','RP','RP'], bell:['BL','BL','BL'], suika:['SK','SK','SK'], cherry:['CH','*','*'], big:['R7','R7','R7'], reg:['LN','LN','LN'] };
const ORDER = ['replay','bell','suika','cherry','big','reg'];
function make(reels) {
  const sym = (r, p, row) => reels[r][(p + (3 - row)) % N];
  function evaluate(pos) {
    const hits = [];
    for (const line of LINES) {
      const s = [sym(0,pos[0],line[0]), sym(1,pos[1],line[1]), sym(2,pos[2],line[2])];
      for (const n of ORDER) { const c = COMBOS[n]; if (c.every((x,i)=>x==='*'||x===s[i])) hits.push(n); }
    }
    return hits;
  }
  const memo = new Map();
  function value(want, st) {
    const rem = [0,1,2].filter(r => st[r] === null);
    if (!rem.length) { const h = evaluate(st); const bad = h.some(x=>x!==want); return [bad?0:1, (!bad && h.includes(want))?1:0]; }
    const k = want + ':' + st.join(',');
    if (memo.has(k)) return memo.get(k);
    let s=0,h=0,c=0;
    for (const r of rem) for (let pr=0; pr<N; pr++) { st[r]=decide(want,st,r,pr); const v=value(want,st); st[r]=null; s+=v[0]; h+=v[1]; c++; }
    const v=[s/c,h/c]; memo.set(k,v); return v;
  }
  function decide(want, st, r, press) {
    let best=null,bs=-1,bh=-1;
    for (let d=0; d<=SLIP; d++) { const p=(press+d)%N; st[r]=p; const [s,h]=value(want,st); st[r]=null;
      if (s>bs+1e-9 || (Math.abs(s-bs)<=1e-9 && h>bh+1e-9)) { best=p; bs=s; bh=h; } }
    return best;
  }
  return { evaluate, value, decide };
}
function score(reels) {
  const m = make(reels); const res = {};
  for (const w of ['none', ...ORDER]) { const v = m.value(w, [null,null,null]); res[w] = v; }
  return res;
}
function cost(res) {
  let c = 0;
  for (const w of ['none', ...ORDER]) c += (1 - res[w][0]) * 1000; // 安全でないのは致命的
  c += (1 - res.replay[1]) * 300 + (1 - res.bell[1]) * 200 + (1 - res.cherry[1]) * 300;
  c += Math.abs(res.suika[1] - 0.5) * 20 + Math.abs(res.big[1] - 0.2) * 20 + Math.abs(res.reg[1] - 0.15) * 20;
  return c;
}
const fs = require('fs');
const src = fs.readFileSync(__dirname + '/../shared/slot_engine.lua', 'utf8');
let reels = [...src.matchAll(/\{ ('[A-Z0-9]{2}'(?:, '[A-Z0-9]{2}'){20}) \}/g)].map(m => m[1].replace(/'/g,'').split(', '));
let best = score(reels), bestC = cost(best);
console.log('現在', bestC.toFixed(2), JSON.stringify(best));
const iters = +(process.argv[2] || 300);
for (let i = 0; i < iters; i++) {
  const cand = reels.map(r => r.slice());
  const r = Math.floor(Math.random()*3), a = Math.floor(Math.random()*N), b = Math.floor(Math.random()*N);
  [cand[r][a], cand[r][b]] = [cand[r][b], cand[r][a]];
  const s = score(cand), c = cost(s);
  if (c <= bestC) { reels = cand; best = s; if (c < bestC) console.log(i, c.toFixed(2)); bestC = c; }
}
console.log('結果', bestC.toFixed(2));
for (const w of ['none', ...ORDER]) console.log(w.padEnd(7), '安全', (best[w][0]*100).toFixed(2)+'%', '揃う', (best[w][1]*100).toFixed(2)+'%');
reels.forEach(r => console.log("{ " + r.map(x=>`'${x}'`).join(', ') + " },"));
// node reel-search.js 0 sweep : 全リールの全ての入れ替えを試して一番良いものを採る（良くならなくなるまで）
if (process.argv[3] === 'sweep') {
  for (let round = 0; round < 6; round++) {
    let improved = null;
    for (let r = 0; r < 3; r++) for (let a = 0; a < N; a++) for (let b = a + 1; b < N; b++) {
      if (reels[r][a] === reels[r][b]) continue;
      const cand = reels.map(x => x.slice()); [cand[r][a], cand[r][b]] = [cand[r][b], cand[r][a]];
      const s = score(cand), c = cost(s);
      if (c < bestC - 1e-9) { bestC = c; best = s; improved = cand; }
    }
    if (!improved) break;
    reels = improved; console.log('round', round, bestC.toFixed(3));
  }
  for (const w of ['none', ...ORDER]) console.log(w.padEnd(7), '安全', (best[w][0]*100).toFixed(2)+'%', '揃う', (best[w][1]*100).toFixed(2)+'%');
  reels.forEach(r => console.log("{ " + r.map(x=>`'${x}'`).join(', ') + " },"));
}
