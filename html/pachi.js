// ta-arcade のパチンコ「宵花火」の画面。玉の行き先も当たり外れもサーバーが決め、ここは見せるだけ
//   Lua から pachi:open / pachi:tick / pachi:fire / pachi:close / pachi:data が来る
//   玉は盤面の上を落ちていくが、行き先はサーバーの返事（shot.to）に合わせて寄せる
(() => {
  'use strict';

  const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'ta-arcade';
  const Q = new URLSearchParams(location.search);
  const PREVIEW = Q.has('preview') && Q.has('pachi');
  const $ = (id) => document.getElementById(id);
  const fmt = (n) => Math.floor(n || 0).toLocaleString('ja-JP');
  const rand = (a, b) => a + Math.random() * (b - a);

  // ---- 盤面の寸法（canvas の中の座標。左上が 0,0） ----
  const W = 560, H = 584;
  const CX = 280, CY = 292, R = 262;           // 盤面の円
  const LCD = { x: 150, y: 136, w: 260, h: 160 }; // 液晶（index.html の .p-lcd と同じ位置）
  const POCKET = {
    heso: { x: 280, y: 374 },      // まん中のヘソ
    denchu: { x: 420, y: 398 },    // 右の電チュー
    attacker: { x: 388, y: 462 },  // 右下のアタッカー
    out: { x: 280, y: 540 },       // アウト口
  };
  const BALL_R = 6, NAIL_R = 3;
  const RAIL_R = R - 12;            // 発射レール（円の内側に沿って上る）
  const RAIL_FROM = 150;            // 左下（度。右が 0、下が 90、左が 180、上が 270）

  // ---- 状態 ----
  const P = {
    open: false,
    info: null,
    firing: false,
    price: 20000, lend: 25, interval: 600, fall: 2400, roundCount: 9, jitan: 100,
    balls: [],          // 飛んでいる玉
    spin: null,         // いまの変動 { start, duration, reach, hit, digits, t1, t2, t3, called, done }
    gain: 0,            // 大当たり中にもらった賞球の合計
    lastPay: 0,
    flash: {},          // 入賞口が光る残り時間
    muted: false,
    userScale: 1,
    callTimer: null,
  };

  // ---- 通信 ----
  async function post(name, data = {}) {
    if (PREVIEW) return Mock.post(name, data);
    try {
      const r = await fetch(`https://${RES}/${name}`, { method: 'POST', headers: { 'Content-Type': 'application/json; charset=UTF-8' }, body: JSON.stringify(data) });
      return await r.json();
    } catch (e) {
      return { ok: false, reason: '通信に失敗しました' };
    }
  }

  // ---- 音（Web Audio で作る） ----
  let ac = null;
  function tone(freq, dur, type = 'square', vol = 0.06, when = 0) {
    if (P.muted) return;
    try {
      ac = ac || new (window.AudioContext || window.webkitAudioContext)();
      const t = ac.currentTime + when;
      const o = ac.createOscillator(), g = ac.createGain();
      o.type = type; o.frequency.setValueAtTime(freq, t);
      g.gain.setValueAtTime(vol, t);
      g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
      o.connect(g).connect(ac.destination);
      o.start(t); o.stop(t + dur + 0.02);
    } catch (e) { /* 音が出なくても続ける */ }
  }
  const sfx = {
    shot: () => tone(210, 0.04, 'triangle', 0.07),
    nail: () => tone(rand(2400, 3200), 0.015, 'square', 0.012),
    heso: () => { tone(880, 0.07, 'sine', 0.08); tone(1320, 0.09, 'sine', 0.07, 0.06); },
    pay: () => tone(1500, 0.03, 'square', 0.035),
    stop: () => tone(520, 0.05, 'square', 0.05),
    reach: () => { [659, 784, 988].forEach((f, i) => tone(f, 0.28, 'sine', 0.08, i * 0.12)); },
    hit: () => { [523, 659, 784, 1047, 784, 1047, 1319].forEach((f, i) => tone(f, 0.24, 'triangle', 0.09, i * 0.12)); },
    round: () => { tone(784, 0.1, 'triangle', 0.08); tone(1047, 0.14, 'triangle', 0.08, 0.1); },
    end: () => { [1047, 784, 659, 523].forEach((f, i) => tone(f, 0.2, 'sine', 0.07, i * 0.12)); },
    deny: () => tone(140, 0.15, 'sawtooth', 0.05),
  };

  // =====================================================================
  // 盤面
  // =====================================================================
  const cv = $('pBoard');
  const ctx = cv.getContext('2d');

  // 釘。互い違いの格子を作り、液晶・入賞口・保留の表示にかかるものを抜く
  const nails = [];
  (function makeNails() {
    const clear = (x, y) => {
      if (Math.hypot(x - CX, y - CY) > R - 30) return false;
      if (x > LCD.x - 16 && x < LCD.x + LCD.w + 16 && y > LCD.y - 18 && y < LCD.y + LCD.h + 44) return false; // 液晶と保留
      if (Math.abs(x - POCKET.heso.x) < 30 && y > POCKET.heso.y - 40 && y < POCKET.heso.y + 30) return false;
      if (Math.abs(x - POCKET.denchu.x) < 34 && y > POCKET.denchu.y - 30 && y < POCKET.denchu.y + 24) return false;
      if (Math.abs(x - POCKET.attacker.x) < 64 && y > POCKET.attacker.y - 30 && y < POCKET.attacker.y + 28) return false;
      if (Math.abs(x - POCKET.out.x) < 40 && y > POCKET.out.y - 34) return false;
      return true;
    };
    let row = 0;
    for (let y = 62; y < 540; y += 31, row++) {
      for (let x = 44 + (row % 2) * 18; x < W - 30; x += 36) {
        if (clear(x, y)) nails.push({ x, y });
      }
    }
    // ヘソの上の 2 本（命釘）と、ヘソへ寄せる 2 本
    const hy = POCKET.heso.y;
    nails.push({ x: 265, y: hy - 20 }, { x: 295, y: hy - 20 }, { x: 246, y: hy - 36 }, { x: 314, y: hy - 36 });
  })();

  // 動かない絵（背景・花火・レール・釘）は一度だけ別の canvas に描いておく
  const bg = document.createElement('canvas');
  function paintBackground(ratio) {
    bg.width = Math.round(W * ratio); bg.height = Math.round(H * ratio);
    const g = bg.getContext('2d');
    g.setTransform(ratio, 0, 0, ratio, 0, 0);
    // 円の外は黒漆。四隅に金の筋を入れる
    g.fillStyle = '#07060b';
    g.fillRect(0, 0, W, H);
    g.strokeStyle = 'rgba(217, 166, 64, .28)'; g.lineWidth = 1;
    for (let i = 1; i <= 5; i++) {
      const o = i * 9;
      for (const [x, y, sx, sy] of [[0, 0, 1, 1], [W, 0, -1, 1], [0, H, 1, -1], [W, H, -1, -1]]) {
        g.beginPath(); g.moveTo(x + sx * o, y); g.lineTo(x, y + sy * o); g.stroke();
      }
    }
    // 宵の空
    const sky = g.createRadialGradient(CX, CY - 60, 40, CX, CY, R);
    sky.addColorStop(0, '#26306e'); sky.addColorStop(0.6, '#121a44'); sky.addColorStop(1, '#080b20');
    g.beginPath(); g.arc(CX, CY, R, 0, Math.PI * 2); g.fillStyle = sky; g.fill();
    // 遠くの花火（盤面の絵）
    g.save();
    g.beginPath(); g.arc(CX, CY, R, 0, Math.PI * 2); g.clip();
    const bloom = (x, y, r, color, n) => {
      g.strokeStyle = color; g.lineWidth = 1.4; g.lineCap = 'round';
      for (let i = 0; i < n; i++) {
        const a = (Math.PI * 2 * i) / n;
        g.globalAlpha = 0.34;
        g.beginPath();
        g.moveTo(x + Math.cos(a) * r * 0.25, y + Math.sin(a) * r * 0.25);
        g.lineTo(x + Math.cos(a) * r, y + Math.sin(a) * r);
        g.stroke();
        g.globalAlpha = 0.5;
        g.beginPath(); g.arc(x + Math.cos(a) * r, y + Math.sin(a) * r, 1.6, 0, Math.PI * 2); g.fillStyle = color; g.fill();
      }
      g.globalAlpha = 1;
    };
    bloom(96, 226, 62, '#e8452c', 18);
    bloom(468, 200, 70, '#f6d98a', 20);
    bloom(176, 470, 54, '#7fb8ff', 16);
    bloom(280, 76, 46, '#f6d98a', 14);
    bloom(476, 340, 38, '#e8452c', 12);
    g.restore();
    // 外枠のレール
    g.lineWidth = 6; g.strokeStyle = '#d9a640';
    g.beginPath(); g.arc(CX, CY, R, 0, Math.PI * 2); g.stroke();
    g.lineWidth = 2; g.strokeStyle = '#7a5a14';
    g.beginPath(); g.arc(CX, CY, R - 20, Math.PI * 0.78, Math.PI * 1.62); g.stroke(); // 発射レールの内側
    // 釘
    for (const n of nails) {
      g.beginPath(); g.arc(n.x, n.y, NAIL_R, 0, Math.PI * 2); g.fillStyle = '#c9952e'; g.fill();
      g.beginPath(); g.arc(n.x - 0.8, n.y - 0.8, 1.1, 0, Math.PI * 2); g.fillStyle = '#fff3c4'; g.fill();
    }
    // アウト口
    g.fillStyle = '#000';
    g.beginPath(); g.ellipse(POCKET.out.x, POCKET.out.y, 26, 9, 0, 0, Math.PI * 2); g.fill();
    g.lineWidth = 2; g.strokeStyle = '#7a5a14'; g.stroke();
  }

  function layout() {
    if (!P.open) return;
    const s = scale();
    $('pachiScaler').style.transform = `scale(${s})`;
    const ratio = Math.min(3, Math.max(1, (window.devicePixelRatio || 1) * s));
    cv.width = Math.round(W * ratio); cv.height = Math.round(H * ratio);
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    paintBackground(ratio);
  }
  function scale() {
    const w = $('pachiScaler').offsetWidth || 928, h = 975; // 管理パネルが出ると横に広がる
    return Math.min(innerHeight * 0.95 / h, innerWidth * 0.96 / w) * P.userScale;
  }
  window.addEventListener('resize', layout);

  // 入賞口を描く（開いているかどうかで変わるので毎回描く）
  function drawPockets(now) {
    const info = P.info || {};
    const support = info.mode && info.mode !== 'normal';
    const jp = info.jackpot;
    const lit = (k) => (P.flash[k] || 0) > now;

    // ヘソ
    const h = POCKET.heso;
    ctx.fillStyle = lit('heso') ? '#ffd5a8' : '#e8452c';
    ctx.beginPath(); ctx.moveTo(h.x - 15, h.y - 8); ctx.lineTo(h.x + 15, h.y - 8); ctx.lineTo(h.x + 10, h.y + 10); ctx.lineTo(h.x - 10, h.y + 10); ctx.closePath(); ctx.fill();
    ctx.fillStyle = '#12060a';
    ctx.beginPath(); ctx.ellipse(h.x, h.y - 6, 11, 4, 0, 0, Math.PI * 2); ctx.fill();

    // 電チュー（確変・時短中は羽根が開く）
    const d = POCKET.denchu;
    ctx.strokeStyle = support ? '#cfe4ff' : '#4a5a8a'; ctx.lineWidth = 4; ctx.lineCap = 'round';
    const wing = support ? 20 : 8;
    ctx.beginPath(); ctx.moveTo(d.x - 9, d.y + 6); ctx.lineTo(d.x - 9 - wing, d.y - 12); ctx.stroke();
    ctx.beginPath(); ctx.moveTo(d.x + 9, d.y + 6); ctx.lineTo(d.x + 9 + wing, d.y - 12); ctx.stroke();
    ctx.fillStyle = lit('denchu') ? '#fff' : (support ? '#7fb8ff' : '#2a3566');
    ctx.fillRect(d.x - 11, d.y, 22, 12);

    // アタッカー（大当たり中に開く）
    const a = POCKET.attacker;
    const open = jp && jp.open;
    ctx.fillStyle = lit('attacker') ? '#fff' : (open ? '#f6d98a' : '#3d2c10');
    ctx.fillRect(a.x - 48, a.y - 2, 96, 14);
    ctx.strokeStyle = open ? '#fff3c4' : '#6d5320'; ctx.lineWidth = 2;
    ctx.strokeRect(a.x - 48, a.y - 2, 96, 14);
    if (open) {
      ctx.fillStyle = '#12060a';
      ctx.fillRect(a.x - 44, a.y + 1, 88, 5);
    }
  }

  // ---- 玉 ----
  function launch(shot) {
    const info = P.info || {};
    const right = (info.mode && info.mode !== 'normal') || !!info.jackpot || shot.to === 'denchu' || shot.to === 'attacker';
    const target = shot.to === 'miss'
      ? { x: POCKET.out.x + rand(-10, 10), y: POCKET.out.y }
      : POCKET[shot.to];
    P.balls.push({
      phase: 'rail',
      a: RAIL_FROM,
      aEnd: right ? rand(300, 316) : rand(236, 272),
      x: 0, y: 0, vx: 0, vy: 0,
      to: shot.to, pay: shot.pay || 0, target,
      born: performance.now(),
      wobble: rand(-1, 1),
    });
    sfx.shot();
  }

  function land(b, now) {
    b.phase = 'done';
    if (b.to === 'miss') return;
    P.flash[b.to] = now + 180;
    if (b.to === 'attacker') { sfx.pay(); P.gain += b.pay; } else sfx.heso();
    P.lastPay = b.pay;
    showNumbers();
  }

  function stepBall(b, now, dt) {
    const age = now - b.born;
    if (b.phase === 'rail') {
      // レールに沿って上り、決めた角度で放す
      b.a += dt * 0.42; // 度 / ミリ秒
      const rad = b.a * Math.PI / 180;
      b.x = CX + Math.cos(rad) * RAIL_R; b.y = CY + Math.sin(rad) * RAIL_R;
      if (b.a >= b.aEnd) {
        b.phase = 'fall';
        b.vx = -Math.sin(rad) * 150; b.vy = Math.cos(rad) * 150;
      }
      return;
    }
    const s = dt / 1000;
    const t = b.target;
    const left = P.fall - age; // 届くまでの残り時間
    if (left < 380) {
      // 時間が来たら、行き先へまっすぐ寄せる（サーバーの時計に合わせる）
      const k = Math.min(1, dt / Math.max(40, left));
      b.x += (t.x - b.x) * k; b.y += (t.y - b.y) * k;
      if (left <= 0 || Math.hypot(t.x - b.x, t.y - b.y) < 5) land(b, now);
      return;
    }
    // 重力と、行き先への寄せ（下へ行くほど強く）
    const prog = Math.min(1, Math.max(0, (b.y - 50) / (t.y - 50)));
    b.vy += 560 * s;
    b.vx += ((t.x - b.x) * (1.5 + 9 * prog * prog) + b.wobble * 40 * (1 - prog)) * s;
    b.vx *= 1 - 1.6 * s; b.vy *= 1 - 0.9 * s;
    b.x += b.vx * s; b.y += b.vy * s;

    // 釘
    for (const n of nails) {
      const dx = b.x - n.x, dy = b.y - n.y;
      const dist = Math.hypot(dx, dy), min = BALL_R + NAIL_R;
      if (dist < min && dist > 0.001) {
        const nx = dx / dist, ny = dy / dist;
        b.x = n.x + nx * min; b.y = n.y + ny * min;
        const dot = b.vx * nx + b.vy * ny;
        if (dot < 0) { b.vx -= 1.5 * dot * nx; b.vy -= 1.5 * dot * ny; if (dot < -90) sfx.nail(); }
      }
    }
    // 液晶（横へ逃がす）
    if (b.x > LCD.x - BALL_R && b.x < LCD.x + LCD.w + BALL_R && b.y > LCD.y - BALL_R && b.y < LCD.y + LCD.h + BALL_R) {
      if (b.y - b.vy * s <= LCD.y - BALL_R + 2) {
        b.y = LCD.y - BALL_R; b.vy = -Math.abs(b.vy) * 0.3;
        b.vx += (b.x < CX ? -1 : 1) * 60;
      } else if (b.x < CX) { b.x = LCD.x - BALL_R; b.vx = -Math.abs(b.vx) * 0.4; } else { b.x = LCD.x + LCD.w + BALL_R; b.vx = Math.abs(b.vx) * 0.4; }
    }
    // 外枠
    const dx = b.x - CX, dy = b.y - CY, dist = Math.hypot(dx, dy), max = R - 14;
    if (dist > max) {
      const nx = dx / dist, ny = dy / dist;
      b.x = CX + nx * max; b.y = CY + ny * max;
      const dot = b.vx * nx + b.vy * ny;
      if (dot > 0) { b.vx -= 1.4 * dot * nx; b.vy -= 1.4 * dot * ny; }
    }
    // ハズレの玉は入賞口から逸らす
    if (b.to === 'miss') {
      for (const k of ['heso', 'denchu', 'attacker']) {
        const p = POCKET[k], w = k === 'attacker' ? 56 : 20;
        if (Math.abs(b.x - p.x) < w && Math.abs(b.y - p.y) < 22) b.vx += (b.x < p.x ? -1 : 1) * 900 * s;
      }
    }
    if (Math.hypot(t.x - b.x, t.y - b.y) < 9 || b.y > H) land(b, now);
  }

  function drawBalls() {
    for (const b of P.balls) {
      const g = ctx.createRadialGradient(b.x - 2, b.y - 2, 1, b.x, b.y, BALL_R);
      g.addColorStop(0, '#fff'); g.addColorStop(0.5, '#cfd2da'); g.addColorStop(1, '#5d6170');
      ctx.beginPath(); ctx.arc(b.x, b.y, BALL_R, 0, Math.PI * 2); ctx.fillStyle = g; ctx.fill();
    }
  }

  // =====================================================================
  // 液晶（図柄と花火）
  // =====================================================================
  const sky = $('pSky').getContext('2d');
  const sparks = [];
  const stars = Array.from({ length: 26 }, () => ({ x: rand(0, 260), y: rand(0, 110), r: rand(0.4, 1.2) }));
  const COLORS = ['#e8452c', '#f6d98a', '#7fb8ff', '#ffffff', '#ff9d8a'];

  function burst(x, y, n, color) {
    const c = color || COLORS[Math.floor(Math.random() * COLORS.length)];
    for (let i = 0; i < n; i++) {
      const a = (Math.PI * 2 * i) / n + rand(-0.1, 0.1), v = rand(40, 110);
      sparks.push({ x, y, vx: Math.cos(a) * v, vy: Math.sin(a) * v, life: rand(700, 1200), age: 0, c });
    }
  }
  function drawSky(dt) {
    sky.clearRect(0, 0, 260, 160);
    sky.fillStyle = 'rgba(255,255,255,.7)';
    for (const s of stars) { sky.beginPath(); sky.arc(s.x, s.y, s.r, 0, Math.PI * 2); sky.fill(); }
    for (let i = sparks.length - 1; i >= 0; i--) {
      const p = sparks[i];
      p.age += dt;
      if (p.age >= p.life) { sparks.splice(i, 1); continue; }
      const s = dt / 1000;
      p.vy += 60 * s; p.vx *= 1 - 1.2 * s; p.vy *= 1 - 1.2 * s;
      p.x += p.vx * s; p.y += p.vy * s;
      sky.globalAlpha = 1 - p.age / p.life;
      sky.fillStyle = p.c;
      sky.beginPath(); sky.arc(p.x, p.y, 1.8, 0, Math.PI * 2); sky.fill();
    }
    sky.globalAlpha = 1;
  }

  const digitEls = Array.from($('pDigits').children);
  function setDigit(i, n, cls) {
    const el = digitEls[i];
    const text = String(n);
    if (el.textContent !== text) el.textContent = text;
    const want = cls || (n % 2 ? 'odd' : 'even');
    if (el.className !== want) el.className = want;
  }
  function call(text, kind, ms) {
    const el = $('pCall');
    clearTimeout(P.callTimer);
    if (!text) { el.classList.add('hidden'); return; }
    el.textContent = text;
    el.className = 'p-call' + (kind ? ' ' + kind : '');
    if (ms) P.callTimer = setTimeout(() => el.classList.add('hidden'), ms);
  }

  // サーバーから変動が始まった知らせが来た。elapsed は、サーバーで始まってから過ぎた時間
  function startSpin(ev) {
    const D = ev.duration;
    const t1 = Math.min(1000, D * 0.3), t2 = Math.min(1700, D * 0.5);
    const t3 = ev.reach ? D - 300 : Math.min(2600, D - 150);
    P.spin = { start: performance.now() - (ev.elapsed || 0), duration: D, reach: ev.reach, hit: ev.hit, digits: ev.digits, t1, t2, t3, called: false, done: false, stopped: [false, false, false] };
    $('pDigits').classList.remove('win');
    call(null);
  }

  function stepSpin(now) {
    const sp = P.spin;
    if (!sp) return;
    const t = now - sp.start;
    const roll = (i) => ((Math.floor(now / 55) + i * 3) % 9) + 1;
    const stopAt = [sp.t1, sp.t3, sp.t2]; // 左・中・右。止まる順は 左 → 右 → 中
    for (let i = 0; i < 3; i++) {
      if (t >= stopAt[i]) {
        setDigit(i, sp.digits[i]);
        if (!sp.stopped[i]) { sp.stopped[i] = true; if (t < sp.duration + 400) sfx.stop(); }
      } else if (i === 1 && sp.reach && t >= sp.t2) {
        // リーチ: 中の図柄がゆっくり進んで、最後に止まる図柄に着く
        const leftSteps = Math.ceil((sp.t3 - t) / 380);
        setDigit(1, ((sp.digits[1] - 1 - leftSteps) % 9 + 9) % 9 + 1, 'slow');
      } else {
        setDigit(i, roll(i), 'roll');
      }
    }
    if (sp.reach && !sp.called && t >= sp.t2 && t < sp.t3) {
      sp.called = true;
      call('リーチ');
      sfx.reach();
      burst(rand(60, 200), rand(30, 70), 14);
    }
    if (!sp.done && t >= sp.t3) {
      sp.done = true;
      if (sp.hit) {
        $('pDigits').classList.add('win');
        call('大当たり', 'hit');
        if (t < sp.duration + 400) sfx.hit();
        for (let i = 0; i < 4; i++) setTimeout(() => burst(rand(40, 220), rand(25, 90), 22), i * 220);
      } else {
        call(null);
      }
    }
    if (t >= sp.duration) P.spin = null;
  }

  // =====================================================================
  // 数字と表示
  // =====================================================================
  function flying(pred) { return P.balls.filter((b) => b.phase !== 'done' && pred(b)); }

  // 持ち玉と保留は、飛んでいる玉が届いてから増やして見せる
  function showNumbers() {
    const info = P.info;
    if (!info) return;
    const pending = flying((b) => b.pay > 0).reduce((n, b) => n + b.pay, 0);
    const balls = Math.max(0, info.balls - pending);
    $('pBalls').textContent = fmt(balls);
    $('pBallsYen').textContent = `${fmt(balls * P.price)}円`;
    $('pTrayBalls').style.height = `${Math.min(44, Math.ceil(balls / 12) * 2)}px`;
    $('pPay').textContent = fmt(info.jackpot ? P.gain : P.lastPay);
    const hold = Math.max(0, info.hold - flying((b) => b.to === 'heso' || b.to === 'denchu').length);
    Array.from($('pHold').children).forEach((el, i) => el.classList.toggle('on', i < hold));
  }

  function historyHtml(list) {
    if (!list || !list.length) return '<li class="none">まだありません</li>';
    return list.map((h) => `<li><span class="${h.t === 'kakuhen' ? 'k' : 'n'}">${h.t === 'kakuhen' ? '確変' : '通常'} ${h.r || ''}R</span><span>${fmt(h.g)} 回転</span></li>`).join('');
  }

  function applyInfo(info) {
    const before = P.info;
    P.info = info;
    const d = info.data || {};
    $('pSince').textContent = fmt(d.since);
    $('pKakuhen').textContent = fmt(d.kakuhen);
    $('pNormal').textContent = fmt(d.normal);
    $('pTotal').textContent = fmt(d.total);
    $('pCash').textContent = `${fmt(info.cash)}円`;
    $('pHistory').innerHTML = historyHtml(d.history);

    const jp = info.jackpot;
    const kind = jp ? 'jackpot' : info.mode;
    $('pCrown').className = 'p-crown' + (kind !== 'normal' ? ' ' + kind : '');
    $('pRight').classList.toggle('hidden', kind === 'normal');
    const state = $('pState');
    state.className = 'state' + (kind !== 'normal' ? ' ' + kind : '');
    $('pStateText').textContent = jp ? `大当たり ${jp.round} / ${jp.rounds}R`
      : info.mode === 'kakuhen' ? '確変中'
        : info.mode === 'jitan' ? `時短 残り ${info.jitanLeft}` : (P.firing ? '打ち出し中' : 'スペースで打つ');

    const row = $('pModeRow');
    row.classList.toggle('hidden', info.mode === 'normal' || !!jp);
    row.classList.toggle('jitan', info.mode === 'jitan');
    $('pModeLabel').textContent = info.mode === 'kakuhen' ? '確変' : '時短';
    $('pModeLeft').textContent = info.mode === 'kakuhen' ? '次の大当たりまで' : `残り ${info.jitanLeft} 回転`;

    // 大当たり中はラウンドを出し、図柄は小さくする
    $('pRound').classList.toggle('hidden', !jp);
    $('pDigits').classList.toggle('small', !!jp);
    if (jp) {
      $('pRoundNo').textContent = `ROUND ${jp.round} / ${jp.rounds}`;
      $('pRoundDots').innerHTML = Array.from({ length: P.roundCount }, (_, i) => `<i class="${i < jp.count ? 'on' : ''}"></i>`).join('');
      if (!before || !before.jackpot) { P.gain = 0; call(null); $('pDigits').classList.remove('win'); }
      else if (before.jackpot.round !== jp.round) sfx.round();
    }
    showNumbers();

    const shown = !$('pachiAdmin').classList.contains('hidden');
    if (window.PachiAdminPanel && window.PachiAdminPanel.render(info) !== shown) layout();
  }

  function setFiring(on) {
    P.firing = on;
    $('pHandle').classList.toggle('on', on);
    if (P.info) applyInfo(P.info);
  }

  let toastTimer = null;
  function toast(text) {
    const el = $('pToast');
    el.textContent = text;
    el.classList.remove('hidden');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.add('hidden'), 2200);
  }

  // ---- サーバーの返事（1発ごと、または変動の続き） ----
  function onTick(d) {
    if (!P.open) return;
    if (typeof d.firing === 'boolean' && d.firing !== P.firing) setFiring(d.firing);
    if (d.lent) toast(`${fmt(d.lent)}円で ${P.lend}玉を借りました`);
    if (d.shot) launch(d.shot);
    for (const ev of d.events || []) {
      if (ev.t === 'spin') startSpin(ev);
      else if (ev.t === 'jackpotEnd') {
        sfx.end();
        call(ev.mode === 'kakuhen' ? '確変 突入' : `時短 ${P.jitan}回転`, null, 2600);
      } else if (ev.t === 'jitanEnd') {
        toast('時短が終わりました');
      }
    }
    applyInfo(d.info);
  }

  // ---- 描く ----
  let last = 0, fireworkAt = 0;
  function frame(now) {
    if (!P.open) return;
    const dt = Math.min(50, now - (last || now));
    last = now;
    for (const b of P.balls) if (b.phase !== 'done') stepBall(b, now, dt);
    if (P.balls.some((b) => b.phase === 'done')) { P.balls = P.balls.filter((b) => b.phase !== 'done'); showNumbers(); }
    stepSpin(now);
    // 大当たり中は花火を上げ続ける
    if (P.info && P.info.jackpot && now > fireworkAt) { fireworkAt = now + rand(350, 700); burst(rand(30, 230), rand(20, 80), 18); }

    ctx.clearRect(0, 0, W, H);
    ctx.drawImage(bg, 0, 0, W, H);
    drawPockets(now);
    drawBalls();
    drawSky(dt);
    requestAnimationFrame(frame);
  }

  // =====================================================================
  // Lua から・キー
  // =====================================================================
  function open(d) {
    P.price = d.price; P.lend = d.lend; P.interval = d.interval; P.fall = d.fall;
    P.roundCount = d.roundCount; P.jitan = d.jitan; P.userScale = d.scale || 1;
    $('pRate').textContent = `${fmt(d.price)}円 / 玉`;
    $('pLend').textContent = d.lend;
    $('pJitan').textContent = d.jitan;
    P.balls = []; P.spin = null; P.gain = 0; P.lastPay = 0; P.info = null;
    P.open = true;
    $('pachiStage').classList.remove('hidden');
    setFiring(false);
    call(null);
    $('pDigits').classList.remove('win');
    const sp = d.info.spin;
    if (sp) startSpin(sp); // 前の人の変動が残っていた
    else [7, 3, 5].forEach((n, i) => setDigit(i, n));
    applyInfo(d.info);
    layout();
    last = 0;
    requestAnimationFrame(frame);
  }
  function close() {
    P.open = false;
    P.firing = false;
    $('pachiStage').classList.add('hidden');
    $('pachiData').classList.add('hidden');
  }
  function toggleFire() {
    const on = !P.firing;
    setFiring(on);
    post('pachi:fire', { on }).then((res) => { if (!res || !res.ok) setFiring(false); });
  }
  function leave() {
    if (!P.open) return;
    setFiring(false);
    post('pachi:leave');
  }
  function openData(d) {
    const x = d.data || {};
    $('pdId').textContent = '#' + d.id;
    $('pdSince').textContent = fmt(x.since);
    $('pdKakuhen').textContent = fmt(x.kakuhen);
    $('pdNormal').textContent = fmt(x.normal);
    $('pdTotal').textContent = fmt(x.total);
    const hits = (x.kakuhen || 0) + (x.normal || 0);
    $('pdRate').textContent = hits > 0 ? `大当たり合算 1/${(x.total / hits).toFixed(1)}（確変 ${fmt(x.kakuhen)} 回・通常 ${fmt(x.normal)} 回）` : 'まだ大当たりは出ていません';
    $('pdHist').innerHTML = historyHtml(x.history);
    $('pachiData').classList.remove('hidden');
  }
  function closeData() {
    $('pachiData').classList.add('hidden');
    post('pachi:closeData');
  }

  $('pHandle').addEventListener('click', toggleFire);
  $('pLeave').addEventListener('click', leave);
  $('pdClose').addEventListener('click', closeData);
  // ボタンをクリックした後にスペースで同じボタンが押されないよう、フォーカスを外す
  document.addEventListener('mouseup', () => { if (document.activeElement && document.activeElement.blur) document.activeElement.blur(); });

  window.addEventListener('keydown', (e) => {
    if (!$('pachiData').classList.contains('hidden')) {
      if (e.key === 'Escape' || e.key === 'Backspace' || e.key === 'Enter') { e.preventDefault(); closeData(); }
      return;
    }
    if (!P.open || e.repeat) return;
    switch (e.key) {
      case ' ': case 'Enter': e.preventDefault(); toggleFire(); break;
      case 'm': case 'M': P.muted = !P.muted; toast(P.muted ? '音を消しました' : '音を出します'); break;
      case 'Escape': case 'Backspace': leave(); break;
    }
  });

  window.PachiApp = { applyInfo: (info) => { if (P.open) applyInfo(info); } };

  window.addEventListener('message', (e) => {
    const d = e.data || {};
    if (d.action === 'pachi:open') open(d);
    else if (d.action === 'pachi:tick') onTick(d);
    else if (d.action === 'pachi:fire') setFiring(d.on === true);
    else if (d.action === 'pachi:close') close();
    else if (d.action === 'pachi:data') openData(d);
  });

  // =====================================================================
  // ブラウザで見るための見本（?preview&pachi）
  //   &pachi=kakuhen / jitan / jackpot で状態、&hit で次の変動が当たり、&fire で打ち始める、
  //   &pachiadmin で管理パネル、&pachidata でデータ表示
  // 見やすいよう、ヘソに入る割合と当たる割合は本物より高くしてある
  // =====================================================================
  const Mock = {
    balls: 240, cash: 15230000, mode: 'normal', jitanLeft: 0, queue: [], spin: null, jackpot: null, freeAt: 0,
    data: { total: 1234, kakuhen: 4, normal: 3, since: 87, history: [{ t: 'kakuhen', g: 212, r: 10 }, { t: 'normal', g: 54, r: 4 }, { t: 'kakuhen', g: 388, r: 4 }] },
    admin: null, firing: false, forceHit: false,
    info(now) {
      const sp = this.spin, jp = this.jackpot;
      return {
        id: 7, balls: this.balls, cash: this.cash, mode: this.mode, jitanLeft: this.jitanLeft, hold: this.queue.length,
        spin: sp ? { elapsed: now - sp.startAt, duration: sp.endAt - sp.startAt, reach: sp.reach, hit: !!sp.hit, digits: sp.digits } : null,
        jackpot: jp ? { kind: jp.kind, round: jp.round, rounds: jp.rounds, count: jp.count, open: now >= jp.openAt } : null,
        data: this.data, admin: this.admin,
      };
    },
    advance(now, events) {
      while (!this.jackpot) {
        const sp = this.spin;
        if (sp) {
          if (now < sp.endAt) break;
          this.spin = null; this.freeAt = sp.endAt;
          this.data.total++; this.data.since++;
          if (sp.hit) {
            this.jackpot = { kind: sp.hit, rounds: sp.rounds, round: 1, count: 0, openAt: sp.endAt + 2500 };
            this.data[sp.hit]++;
            this.data.history.unshift({ t: sp.hit, g: this.data.since, r: sp.rounds });
            this.data.since = 0;
            events.push({ t: 'jackpot', kind: sp.hit, rounds: sp.rounds });
          } else if (this.mode === 'jitan' && --this.jitanLeft <= 0) { this.mode = 'normal'; events.push({ t: 'jitanEnd' }); }
        } else {
          const q = this.queue[0];
          if (!q) break;
          const t0 = Math.max(q.at, this.freeAt);
          if (t0 > now) break;
          this.queue.shift();
          const support = this.mode !== 'normal';
          let hit = null;
          if (this.forceHit || Math.random() < (this.mode === 'kakuhen' ? 1 / 5 : 1 / 12)) hit = Math.random() < 0.5 ? 'kakuhen' : 'normal';
          this.forceHit = false;
          const reach = !!hit || Math.random() < 0.15;
          const dur = hit ? (support ? 9000 : 16000) : reach ? (support ? 6000 : 12000) : support ? 1800 : (this.queue.length >= 2 ? 3500 : 6000);
          const a = 1 + Math.floor(Math.random() * 9);
          const digits = hit === 'kakuhen' ? [7, 7, 7] : hit === 'normal' ? [4, 4, 4] : reach ? [a, a % 9 + 1, a] : [a, 1 + Math.floor(Math.random() * 9), a % 9 + 1];
          this.spin = { startAt: t0, endAt: t0 + dur, hit, reach, rounds: hit ? (Math.random() < 0.7 ? 4 : 10) : null, digits };
          events.push({ t: 'spin', elapsed: now - t0, duration: dur, reach, hit: !!hit, digits });
        }
      }
    },
    shoot(now, events) {
      const jp = this.jackpot;
      if (jp) {
        if (now < jp.openAt || Math.random() >= 0.9) return { to: 'miss', pay: 0 };
        if (++jp.count >= P.roundCount) {
          if (jp.round >= jp.rounds) {
            this.jackpot = null;
            this.mode = jp.kind === 'kakuhen' ? 'kakuhen' : 'jitan';
            this.jitanLeft = this.mode === 'jitan' ? P.jitan : 0;
            this.freeAt = now + 2500;
            events.push({ t: 'jackpotEnd', mode: this.mode });
          } else { jp.round++; jp.count = 0; jp.openAt = now + 1200; }
        }
        return { to: 'attacker', pay: 15 };
      }
      const via = this.mode === 'normal' ? 'heso' : 'denchu';
      if (Math.random() >= (via === 'heso' ? 0.22 : 0.33)) return { to: 'miss', pay: 0 };
      if (this.queue.length < 4) this.queue.push({ at: now + P.fall, via });
      return { to: via, pay: 3 };
    },
    tick() {
      const now = performance.now();
      const events = [];
      this.advance(now, events);
      let shot = null, lent = null;
      if (this.firing) {
        if (this.balls < 1) { this.balls += P.lend; this.cash -= P.lend * P.price; lent = P.lend * P.price; }
        this.balls--;
        shot = this.shoot(now, events);
        this.balls += shot.pay;
      } else if (!events.length && !this.spin && !this.queue.length) return;
      window.postMessage({ action: 'pachi:tick', shot, events, lent, info: this.info(now), firing: this.firing }, '*');
    },
    post(name, d) {
      if (name === 'pachi:fire') { this.firing = d.on; return { ok: true, on: d.on }; }
      if (name === 'pachi:leave') { this.firing = false; window.postMessage({ action: 'pachi:close' }, '*'); return { ok: true }; }
      if (name === 'pachiAdmin:force') { this.admin = Object.assign({}, this.admin, { force: d.mode }); this.forceHit = !!d.mode; return { ok: true, info: this.info(performance.now()) }; }
      if (name === 'pachiAdmin:setting') { this.admin = Object.assign({}, this.admin, { setting: d.setting }); return { ok: true, info: this.info(performance.now()) }; }
      return { ok: true };
    },
  };
  if (PREVIEW) {
    if (Q.get('bg')) document.body.style.background = `url(${Q.get('bg')}) center/cover`;
    const want = Q.get('pachi');
    if (want === 'kakuhen') Mock.mode = 'kakuhen';
    if (want === 'jitan') { Mock.mode = 'jitan'; Mock.jitanLeft = 63; }
    if (want === 'jackpot') Mock.jackpot = { kind: 'kakuhen', rounds: 10, round: 3, count: 4, openAt: 0 };
    if (Q.has('hit')) Mock.forceHit = true;
    if (Q.has('pachiadmin')) Mock.admin = { setting: 4, force: Q.get('pachiadmin') || null };
    window.addEventListener('load', () => {
      if (Q.has('pachidata')) return openData({ id: 7, data: Mock.data });
      open({ info: Mock.info(performance.now()), price: 20000, lend: 25, maxBalls: 2500, interval: 600, fall: 2400, roundCount: 9, jitan: 100, scale: 1 });
      setInterval(() => Mock.tick(), P.interval);
      if (Q.has('fire')) toggleFire();
    });
  }
})();
