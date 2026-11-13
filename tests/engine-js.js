// engine.lua と同じリール制御の JS 版（開発用の計算に使う。ゲームでは使わない）
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

function readReels(src) {
  return [...src.matchAll(/\{ ('[A-Z0-9]{2}'(?:, '[A-Z0-9]{2}'){20}) \}/g)].map((m) => m[1].replace(/'/g, '').split(', '));
}
module.exports = { N, SLIP, LINES, COMBOS, ORDER, make, readReels };
