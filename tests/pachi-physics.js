// server/pachi_physics.lua を JavaScript に写したもの。測定専用（サーバーで使うのは Lua の方）
// fengari で Lua 版を動かすと 1 玉 30 ミリ秒ほどかかり、入賞の割合を数万玉で測るのに 10 分以上かかるため、
// 同じ計算を同じ順番で書いて速く回す。Lua 版と 1 ビットも違わない軌道になることは pachi-physics-check.js で確かめる
//   const { load, simulate } = require('./pachi-physics');
//   const sim = load();            // 盤面は shared/pachi_board.lua から、数字は server/pachi_physics.lua から読む
//   sim.simulate(power, rnd, gates) → { to, t, path, hits }
const fs = require('fs'), path = require('path');
const { execFileSync } = require('child_process');

function load() {
  // 盤面は Lua の定義をそのまま（桁を落とさずに）書き出して読む
  const B = JSON.parse(execFileSync(process.execPath, [path.join(__dirname, 'lua-run.js'), path.join(__dirname, 'pachi-export.lua'), 'exact'],
    { cwd: __dirname, encoding: 'utf8', env: process.env, maxBuffer: 1 << 26 }));
  // 物理の数字（P.G = 9000.0 など）は Lua のソースから読む（二重に持たない）
  const src = fs.readFileSync(path.join(__dirname, '../server/pachi_physics.lua'), 'utf8');
  const num = (name) => {
    const m = src.match(new RegExp(`^P\\.${name} = ([^\\n-]+?)\\s*(--.*)?$`, 'm'));
    if (!m) throw new Error(`server/pachi_physics.lua に P.${name} がありません`);
    return Function(`return (${m[1]})`)();
  };
  const P = {};
  for (const k of ['G', 'DT', 'MAX_TIME', 'SAMPLE', 'E_NAIL', 'E_WALL', 'E_RUBBER', 'FRICTION', 'REST', 'VMAX']) P[k] = num(k);

  const { sqrt, floor, abs, min, max } = Math;
  const CELL = 32;
  let grid = new Map();
  function addCircle(x, y, r, e, kind) {
    const c = { x, y, r: r + B.ballR, e, kind };
    const x0 = floor((x - c.r) / CELL), x1 = floor((x + c.r) / CELL);
    const y0 = floor((y - c.r) / CELL), y1 = floor((y + c.r) / CELL);
    for (let gy = y0; gy <= y1; gy++) {
      for (let gx = x0; gx <= x1; gx++) {
        const k = gy * 64 + gx;
        if (!grid.has(k)) grid.set(k, []);
        grid.get(k).push(c);
      }
    }
  }
  function build() {
    grid = new Map();
    for (const n of B.nails) addCircle(n.x, n.y, B.nailR, P.E_NAIL, 'nail');
    for (const w of B.windmills) addCircle(w.x, w.y, w.r, P.E_NAIL, 'mill');
    addCircle(B.rubber.x, B.rubber.y, B.rubber.r, P.E_RUBBER, 'rubber');
  }
  build();

  const boxOf = (cx, cy, hw, hh) => ({ x0: cx - hw - B.ballR, x1: cx + hw + B.ballR, y0: cy - hh - B.ballR, y1: cy + hh + B.ballR });
  const LCD = { x0: B.lcd.x - B.ballR, x1: B.lcd.x + B.lcd.w + B.ballR, y0: B.lcd.y - B.ballR, y1: B.lcd.y + B.lcd.h + B.ballR };
  const ATTACKER = boxOf(B.pocket.attacker.x, B.pocket.attacker.y, B.pocket.attacker.w, B.pocket.attacker.h);

  function hitSegment(seg, s) {
    const x1 = seg[0], y1 = seg[1], x2 = seg[2], y2 = seg[3];
    const ex = x2 - x1, ey = y2 - y1;
    let t = ((s.x - x1) * ex + (s.y - y1) * ey) / (ex * ex + ey * ey);
    if (t < 0) t = 0; else if (t > 1) t = 1;
    const dx = s.x - (x1 + ex * t), dy = s.y - (y1 + ey * t);
    const d2 = dx * dx + dy * dy;
    const r = B.ballR;
    if (d2 >= r * r || d2 < 1e-9) return;
    const d = sqrt(d2);
    const nx = dx / d, ny = dy / d;
    s.x = s.x + nx * (r - d); s.y = s.y + ny * (r - d);
    let vn = s.vx * nx + s.vy * ny;
    if (vn < 0) {
      const tx = -ny, ty = nx;
      let vt = s.vx * tx + s.vy * ty;
      if (vn < -P.REST) { vt = vt * P.FRICTION; vn = -vn * P.E_WALL; } else vn = 0.0;
      s.vx = nx * vn + tx * vt; s.vy = ny * vn + ty * vt;
    }
  }

  function hitBox(b, s) {
    const x = s.x, y = s.y;
    if (x <= b.x0 || x >= b.x1 || y <= b.y0 || y >= b.y1) return false;
    const dl = x - b.x0, dr = b.x1 - x, dt = y - b.y0, db = b.y1 - y;
    const m = min(dl, dr, dt, db);
    if (m === dt) {
      s.y = b.y0;
      if (s.vy > 0) s.vy = -s.vy * P.E_WALL;
    } else if (m === db) {
      s.y = b.y1;
      if (s.vy < 0) s.vy = -s.vy * P.E_WALL;
    } else if (m === dl) {
      s.x = b.x0;
      if (s.vx > 0) s.vx = -s.vx * P.E_WALL;
    } else {
      s.x = b.x1;
      if (s.vx < 0) s.vx = -s.vx * P.E_WALL;
    }
    return true;
  }

  function simulate(power, rnd, gates) {
    power = max(0, min(100, power));
    const L = B.launch;
    const v0 = (L.vmin + (L.vmax - L.vmin) * power / 100.0) * (1.0 + (rnd() - 0.5) * 0.05);
    const a = L.angle * Math.PI / 180.0;
    const ca = Math.cos(a), sa = Math.sin(a);
    const rr = B.wall - B.ballR - 0.5;
    const s = { x: B.cx + ca * rr, y: B.cy + sa * rr, vx: -sa * v0, vy: ca * v0 };
    const millSign = rnd() < 0.5 ? -1.0 : 1.0;
    let kick = rnd();

    const dt = P.DT, g = P.G;
    const pathOut = [], hits = [];
    const steps = floor(P.MAX_TIME / dt);
    let to = 'miss';
    let attackerClosed = false;
    let slow = 0;
    let lastX = s.x, lastY = s.y;
    const wallR = B.wall - B.ballR;
    const heso = B.pocket.heso, out = B.pocket.out, generals = B.pocket.general;
    const dn = B.pocket.denchu;
    let step = 0;

    while (step < steps) {
      step = step + 1;
      s.vy = s.vy + g * dt;
      const sp2 = s.vx * s.vx + s.vy * s.vy;
      if (sp2 > P.VMAX * P.VMAX) {
        const k = P.VMAX / sqrt(sp2);
        s.vx = s.vx * k; s.vy = s.vy * k;
      }
      s.x = s.x + s.vx * dt;
      s.y = s.y + s.vy * dt;

      // 釘・風車・返しゴム
      const cell = grid.get(floor(s.y / CELL) * 64 + floor(s.x / CELL));
      if (cell) {
        for (let i = 0; i < cell.length; i++) {
          const c = cell[i];
          const dx = s.x - c.x, dy = s.y - c.y;
          const d2 = dx * dx + dy * dy;
          if (d2 < c.r * c.r && d2 > 1e-9) {
            const d = sqrt(d2);
            const nx = dx / d, ny = dy / d;
            s.x = c.x + nx * c.r; s.y = c.y + ny * c.r;
            let vn = s.vx * nx + s.vy * ny;
            if (vn < 0) {
              const tx = -ny, ty = nx;
              let vt = s.vx * tx + s.vy * ty;
              if (vn < -P.REST) {
                vt = vt * P.FRICTION;
                if (c.kind === 'mill') vt = vt + millSign * 140.0;
                vn = -vn * c.e;
                if (vn > 150 && hits.length < 48) hits.push(floor(step / P.SAMPLE));
              } else {
                vn = 0.0;
              }
              s.vx = nx * vn + tx * vt; s.vy = ny * vn + ty * vt;
            }
          }
        }
      }

      // 外レール
      {
        const dx = s.x - B.cx, dy = s.y - B.cy;
        const d2 = dx * dx + dy * dy;
        if (d2 > wallR * wallR) {
          const d = sqrt(d2);
          const nx = dx / d, ny = dy / d;
          s.x = B.cx + nx * wallR; s.y = B.cy + ny * wallR;
          let vn = s.vx * nx + s.vy * ny;
          if (vn > 0) {
            const tx = -ny, ty = nx;
            const vt = (s.vx * tx + s.vy * ty) * 0.999;
            vn = -vn * P.E_WALL;
            s.vx = nx * vn + tx * vt; s.vy = ny * vn + ty * vt;
          }
        }
      }

      // 液晶と屋根
      hitBox(LCD, s);
      for (let i = 0; i < B.segments.length; i++) hitSegment(B.segments[i], s);

      // 入賞口
      const hx = s.x - heso.x, hy = s.y - heso.y;
      if (hx * hx + hy * hy < heso.r * heso.r) { to = 'heso'; break; }
      let gen = false;
      for (let i = 0; i < generals.length; i++) {
        const p = generals[i];
        const gx = s.x - p.x, gy = s.y - p.y;
        if (gx * gx + gy * gy < p.r * p.r) gen = true;
      }
      if (gen) { to = 'general'; break; }
      if (gates.denchu) {
        if (abs(s.x - dn.x) < dn.w + 4 && abs(s.y - dn.y) < dn.h + 5) { to = 'denchu'; break; }
      } else {
        const ex = s.x - dn.x, ey = s.y - dn.y;
        const e2 = ex * ex + ey * ey, er = dn.w + B.ballR;
        if (e2 < er * er && e2 > 1e-9) {
          const e = sqrt(e2);
          const nx = ex / e, ny = ey / e;
          s.x = dn.x + nx * er; s.y = dn.y + ny * er;
          const vn = s.vx * nx + s.vy * ny;
          if (vn < 0) {
            const vx = s.vx - (1 + P.E_NAIL) * vn * nx, vy = s.vy - (1 + P.E_NAIL) * vn * ny;
            s.vx = vx; s.vy = vy;
          }
        }
      }
      if (!attackerClosed && s.x > ATTACKER.x0 && s.x < ATTACKER.x1 && s.y > ATTACKER.y0 && s.y < ATTACKER.y1) {
        if (gates.attacker && gates.attacker(step * dt * 1000.0)) { to = 'attacker'; break; }
        attackerClosed = true;
      }
      if ((s.y > out.y - 12 && abs(s.x - out.x) < out.w) || s.y > B.cy + wallR - 2) break;

      // 引っ掛かった玉を外す
      if (step % 240 === 0) {
        const mx = s.x - lastX, my = s.y - lastY;
        if (mx * mx + my * my < 36) {
          kick = (kick * 9301.0 + 0.2113) % 1.0;
          s.vx = s.vx + (kick < 0.5 ? -1.0 : 1.0) * (160.0 + slow * 80.0);
          s.vy = s.vy - 120.0;
          slow = slow + 1;
        }
        lastX = s.x; lastY = s.y;
      }

      if (step % P.SAMPLE === 0) {
        pathOut.push(floor(s.x * 2 + 0.5), floor(s.y * 2 + 0.5));
      }
    }
    pathOut.push(floor(s.x * 2 + 0.5), floor(s.y * 2 + 0.5));
    return { to, t: floor(step * dt * 1000.0 + 0.5), path: pathOut, hits };
  }

  return { B, P, simulate, build };
}

// Lua と JavaScript で同じ並びになる乱数（確かめるときに使う）
function lcg(seed) {
  let s = seed;
  return () => { s = (s * 48271) % 2147483647; return s / 2147483647; };
}

module.exports = { load, lcg };
