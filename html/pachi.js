// ta-arcade のパチンコ「宵花火」の画面
//   玉の動きはサーバーが物理計算をして、軌道（1 秒に 50 点）を送ってくる。ここはそれをそのまま再生する
//   当たり外れ・演出の種類・保留の色もサーバーが決める。画面が決めるのは「打つかどうか」と「ハンドルの強さ」だけ
//   Lua から pachi:open / pachi:tick / pachi:fire / pachi:close / pachi:data が来る
(() => {
  'use strict';

  const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'ta-arcade';
  const Q = new URLSearchParams(location.search);
  const PREVIEW = Q.has('preview') && Q.has('pachi');
  const $ = (id) => document.getElementById(id);
  const fmt = (n) => Math.floor(n || 0).toLocaleString('ja-JP');
  const rand = (a, b) => a + Math.random() * (b - a);
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));

  const SAMPLE_MS = 20;        // 軌道の 1 点の間隔（サーバーの PachiPhysics.SAMPLE / 600 秒）
  const RIGHT_POWER = 92;      // ↑ で合わせる右打ちの強さ
  const RIGHT_FROM = 78;       // これ以上なら右打ちとみなす

  // ---- 状態 ----
  const P = {
    open: false,
    board: null,         // 盤面（釘・風車・入賞口）。サーバーの物理計算と同じ並び
    info: null,
    firing: false,
    power: 32, leftPower: 32,
    price: 20000, lend: 25, interval: 600, roundCount: 9, jitan: 100, pay: { heso: 3, denchu: 2, attacker: 15, general: 5 },
    balls: [],           // 飛んでいる玉 { path, t0, dur, to, pay, hits, hi }
    spin: null,          // いまの変動
    cols: null,          // 図柄 3 列の位置
    gain: 0,             // 大当たり中にもらった賞球
    lastPay: 0,
    flash: {},           // 入賞口が光る残り時間
    mills: [],           // 風車の角度と速さ
    card: null,          // 液晶に出す大きな文字 { text, sub, until, color }
    muted: false,
    userScale: 1,
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

  // =====================================================================
  // 音（Web Audio で作る）
  // =====================================================================
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
  let lastNail = 0;
  const sfx = {
    shot: () => { tone(160, 0.05, 'triangle', 0.09); tone(90, 0.06, 'sine', 0.08, 0.01); },
    nail: (now) => { if (now - lastNail > 28) { lastNail = now; tone(rand(2600, 4200), 0.012, 'square', 0.014); } },
    heso: () => { tone(880, 0.07, 'sine', 0.09); tone(1320, 0.1, 'sine', 0.08, 0.06); },
    general: () => { tone(660, 0.06, 'sine', 0.07); tone(990, 0.08, 'sine', 0.06, 0.05); },
    denchu: () => tone(1175, 0.05, 'sine', 0.06),
    // 賞球が皿に出てくる音（玉の数だけ細かく鳴らす）
    payout: (n) => { for (let i = 0; i < Math.min(n, 15); i++) tone(rand(1700, 2300), 0.02, 'square', 0.022, 0.05 + i * 0.035); },
    start: () => { tone(330, 0.06, 'square', 0.04); tone(440, 0.06, 'square', 0.04, 0.05); },
    stop: () => { tone(520, 0.05, 'square', 0.055); tone(260, 0.05, 'triangle', 0.05, 0.01); },
    yokoku: (lv) => { for (let i = 0; i <= lv; i++) tone(700 + i * 260, 0.12, 'sawtooth', 0.04, i * 0.09); },
    reach: () => { [659, 784, 988, 1319].forEach((f, i) => tone(f, 0.3, 'sine', 0.085, i * 0.11)); },
    sp: () => { [392, 494, 587, 784, 988, 1175].forEach((f, i) => tone(f, 0.34, 'triangle', 0.09, i * 0.09)); },
    hit: () => { [523, 659, 784, 1047, 784, 1047, 1319, 1568].forEach((f, i) => tone(f, 0.26, 'triangle', 0.1, i * 0.12)); },
    round: () => { tone(784, 0.1, 'triangle', 0.08); tone(1047, 0.16, 'triangle', 0.08, 0.1); },
    end: () => { [1047, 784, 659, 523].forEach((f, i) => tone(f, 0.22, 'sine', 0.07, i * 0.13)); },
    warn: () => { tone(880, 0.09, 'square', 0.05); tone(880, 0.09, 'square', 0.05, 0.16); },
    deny: () => tone(140, 0.15, 'sawtooth', 0.05),
  };
  // 状態ごとに繰り返す曲（リーチ中・大当たり中）。8 分音符の並びを回す
  const TUNES = {
    reach: { step: 210, notes: [440, 0, 523, 0, 587, 0, 523, 0], type: 'sine', vol: 0.04 },
    sp: { step: 150, notes: [330, 392, 494, 392, 523, 494, 392, 494, 349, 440, 523, 440, 587, 523, 440, 523], type: 'triangle', vol: 0.05 },
    jackpot: { step: 160, notes: [523, 659, 784, 659, 880, 784, 659, 784, 587, 698, 880, 698, 988, 880, 698, 880], type: 'square', vol: 0.03 },
    kakuhen: { step: 240, notes: [392, 0, 494, 587, 0, 494, 392, 0], type: 'sine', vol: 0.025 },
  };
  let tune = null, tuneTimer = null, tuneAt = 0;
  function setTune(name) {
    if (name === tune) return;
    tune = name;
    clearInterval(tuneTimer);
    tuneTimer = null;
    if (!name || !TUNES[name]) return;
    const t = TUNES[name];
    tuneAt = 0;
    tuneTimer = setInterval(() => {
      const f = t.notes[tuneAt++ % t.notes.length];
      if (f) tone(f, t.step / 1000 * 0.9, t.type, t.vol);
    }, t.step);
  }

  // =====================================================================
  // 盤面
  // =====================================================================
  const cv = $('pBoard');
  const ctx = cv.getContext('2d');
  const bg = document.createElement('canvas'); // 動かない絵（空・花火・レール・釘）

  function paintBackground(ratio) {
    const B = P.board;
    bg.width = Math.round(B.W * ratio); bg.height = Math.round(B.H * ratio);
    const g = bg.getContext('2d');
    g.setTransform(ratio, 0, 0, ratio, 0, 0);
    // 円の外は黒漆。四隅に金の筋を入れる
    g.fillStyle = '#07060b';
    g.fillRect(0, 0, B.W, B.H);
    g.strokeStyle = 'rgba(217, 166, 64, .28)'; g.lineWidth = 1;
    for (let i = 1; i <= 5; i++) {
      const o = i * 9;
      for (const [x, y, sx, sy] of [[0, 0, 1, 1], [B.W, 0, -1, 1], [0, B.H, 1, -1], [B.W, B.H, -1, -1]]) {
        g.beginPath(); g.moveTo(x + sx * o, y); g.lineTo(x, y + sy * o); g.stroke();
      }
    }
    // 宵の空
    const sky = g.createRadialGradient(B.cx, B.cy - 60, 40, B.cx, B.cy, B.R);
    sky.addColorStop(0, '#26306e'); sky.addColorStop(0.6, '#121a44'); sky.addColorStop(1, '#080b20');
    g.beginPath(); g.arc(B.cx, B.cy, B.R, 0, Math.PI * 2); g.fillStyle = sky; g.fill();
    // 遠くの花火（盤面の絵）
    g.save();
    g.beginPath(); g.arc(B.cx, B.cy, B.R, 0, Math.PI * 2); g.clip();
    const bloom = (x, y, r, color, n) => {
      g.strokeStyle = color; g.lineWidth = 1.4; g.lineCap = 'round';
      for (let i = 0; i < n; i++) {
        const a = (Math.PI * 2 * i) / n;
        g.globalAlpha = 0.26;
        g.beginPath();
        g.moveTo(x + Math.cos(a) * r * 0.25, y + Math.sin(a) * r * 0.25);
        g.lineTo(x + Math.cos(a) * r, y + Math.sin(a) * r);
        g.stroke();
        g.globalAlpha = 0.4;
        g.beginPath(); g.arc(x + Math.cos(a) * r, y + Math.sin(a) * r, 1.6, 0, Math.PI * 2); g.fillStyle = color; g.fill();
      }
      g.globalAlpha = 1;
    };
    bloom(92, 218, 58, '#e8452c', 18);
    bloom(476, 196, 62, '#f6d98a', 20);
    bloom(170, 486, 52, '#7fb8ff', 16);
    bloom(330, 470, 40, '#e8452c', 12);
    g.restore();
    // 外レール（金）と、左の発射レール（内側の細い線）
    g.lineWidth = 6; g.strokeStyle = '#d9a640';
    g.beginPath(); g.arc(B.cx, B.cy, B.R, 0, Math.PI * 2); g.stroke();
    g.lineWidth = 2; g.strokeStyle = '#7a5a14';
    g.beginPath(); g.arc(B.cx, B.cy, B.wall - 17, Math.PI * 0.8, Math.PI * 1.13); g.stroke();
    // 液晶の屋根
    g.lineWidth = 5; g.strokeStyle = '#d9a640'; g.lineCap = 'round'; g.lineJoin = 'round';
    g.beginPath();
    (B.segments || []).forEach((s, i) => { if (i === 0) g.moveTo(s[0], s[1]); g.lineTo(s[2], s[3]); });
    g.stroke();
    // 返しゴム
    g.fillStyle = '#3a3a40';
    g.beginPath(); g.arc(B.rubber.x, B.rubber.y, B.rubber.r, 0, Math.PI * 2); g.fill();
    g.lineWidth = 1.5; g.strokeStyle = '#77777f'; g.stroke();
    // 釘
    for (const n of B.nails) {
      g.beginPath(); g.arc(n.x, n.y, B.nailR + 0.4, 0, Math.PI * 2); g.fillStyle = '#c9952e'; g.fill();
      g.beginPath(); g.arc(n.x - 0.7, n.y - 0.7, 1.0, 0, Math.PI * 2); g.fillStyle = '#fff3c4'; g.fill();
    }
    // アウト口
    const o = B.pocket.out;
    g.fillStyle = '#000';
    g.beginPath(); g.ellipse(o.x, o.y - 2, o.w - 6, 9, 0, 0, Math.PI * 2); g.fill();
    g.lineWidth = 2; g.strokeStyle = '#7a5a14'; g.stroke();
  }

  function layout() {
    if (!P.open || !P.board) return;
    const B = P.board;
    const s = scale();
    $('pachiScaler').style.transform = `scale(${s})`;
    const ratio = Math.min(3, Math.max(1, (window.devicePixelRatio || 1) * s));
    cv.width = Math.round(B.W * ratio); cv.height = Math.round(B.H * ratio);
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    paintBackground(ratio);
    // 液晶と保留は、盤面の定義の位置に置く
    const el = $('pLcd');
    el.style.left = `${B.lcd.x}px`; el.style.top = `${B.lcd.y}px`;
    el.style.width = `${B.lcd.w}px`; el.style.height = `${B.lcd.h}px`;
    lcdCv.width = Math.round(B.lcd.w * ratio); lcdCv.height = Math.round(B.lcd.h * ratio);
    lcd.setTransform(ratio, 0, 0, ratio, 0, 0);
    const hold = $('pHold');
    hold.style.left = `${B.lcd.x}px`; hold.style.width = `${B.lcd.w}px`; hold.style.top = `${B.lcd.y + B.lcd.h + 12}px`;
  }
  function scale() {
    const w = $('pachiScaler').offsetWidth || 928, h = 975; // 管理パネルが出ると横に広がる
    return Math.min(innerHeight * 0.95 / h, innerWidth * 0.96 / w) * P.userScale;
  }
  window.addEventListener('resize', layout);

  // 動く部品（風車・入賞口）
  function drawParts(now, dt) {
    const B = P.board, info = P.info || {};
    const support = info.mode && info.mode !== 'normal' && !info.jackpot;
    const jp = info.jackpot;
    const lit = (k) => (P.flash[k] || 0) > now;

    // 風車（玉が当たると勢いよく回り、だんだん遅くなる）
    B.windmills.forEach((w, i) => {
      const m = P.mills[i];
      m.a += m.v * dt / 1000;
      m.v += (1.2 - m.v) * Math.min(1, dt / 600);
      ctx.save();
      ctx.translate(w.x, w.y); ctx.rotate(m.a);
      ctx.fillStyle = '#e8452c';
      for (let k = 0; k < 4; k++) {
        ctx.rotate(Math.PI / 2);
        ctx.beginPath(); ctx.moveTo(0, 0); ctx.quadraticCurveTo(w.r * 0.9, -w.r * 0.7, w.r * 1.5, 0); ctx.quadraticCurveTo(w.r * 0.6, w.r * 0.25, 0, 0); ctx.fill();
      }
      ctx.restore();
      ctx.beginPath(); ctx.arc(w.x, w.y, 3, 0, Math.PI * 2); ctx.fillStyle = '#fff3c4'; ctx.fill();
    });

    // 一般入賞口
    for (const p of B.pocket.general) {
      ctx.fillStyle = lit('general') ? '#fff' : '#3fbf6a';
      ctx.beginPath(); ctx.moveTo(p.x - 10, p.y - 3); ctx.lineTo(p.x + 10, p.y - 3); ctx.lineTo(p.x + 7, p.y + 9); ctx.lineTo(p.x - 7, p.y + 9); ctx.closePath(); ctx.fill();
      ctx.fillStyle = '#04120a';
      ctx.beginPath(); ctx.ellipse(p.x, p.y - 2, 7, 3, 0, 0, Math.PI * 2); ctx.fill();
    }

    // ヘソ
    const h = B.pocket.heso;
    ctx.fillStyle = lit('heso') ? '#ffd5a8' : '#e8452c';
    ctx.beginPath(); ctx.moveTo(h.x - 12, h.y - 4); ctx.lineTo(h.x + 12, h.y - 4); ctx.lineTo(h.x + 8, h.y + 12); ctx.lineTo(h.x - 8, h.y + 12); ctx.closePath(); ctx.fill();
    ctx.fillStyle = '#12060a';
    ctx.beginPath(); ctx.ellipse(h.x, h.y - 2, 8, 3.5, 0, 0, Math.PI * 2); ctx.fill();

    // 電チュー（確変・時短中は羽根が開く）
    const d = B.pocket.denchu;
    ctx.lineWidth = 4; ctx.lineCap = 'round';
    ctx.strokeStyle = support ? '#cfe4ff' : '#4a5a8a';
    if (support) {
      ctx.beginPath(); ctx.moveTo(d.x - 8, d.y + 4); ctx.lineTo(d.x - 22, d.y - 12); ctx.stroke();
      ctx.beginPath(); ctx.moveTo(d.x + 8, d.y + 4); ctx.lineTo(d.x + 22, d.y - 12); ctx.stroke();
    } else {
      ctx.beginPath(); ctx.moveTo(d.x - 8, d.y + 4); ctx.lineTo(d.x - 3, d.y - 12); ctx.stroke();
      ctx.beginPath(); ctx.moveTo(d.x + 8, d.y + 4); ctx.lineTo(d.x + 3, d.y - 12); ctx.stroke();
    }
    ctx.fillStyle = lit('denchu') ? '#fff' : (support ? '#7fb8ff' : '#2a3566');
    ctx.fillRect(d.x - 10, d.y, 20, 11);

    // アタッカー（大当たり中に開く。閉じているときは盤面と面一で、玉は前を通る）
    const a = B.pocket.attacker;
    const open = jp && jp.open;
    ctx.fillStyle = lit('attacker') ? '#fff' : (open ? '#f6d98a' : '#2b2010');
    ctx.fillRect(a.x - a.w, a.y - a.h, a.w * 2, a.h * 2);
    ctx.lineWidth = 2; ctx.strokeStyle = open ? '#fff3c4' : '#6d5320';
    ctx.strokeRect(a.x - a.w, a.y - a.h, a.w * 2, a.h * 2);
    if (open) {
      ctx.fillStyle = '#12060a';
      ctx.fillRect(a.x - a.w + 4, a.y - a.h + 3, a.w * 2 - 8, 5);
    }
  }

  // ---- 玉（サーバーの軌道を再生する） ----
  function launch(shot, now) {
    P.balls.push({ path: shot.path, hits: shot.hits || [], hi: 0, t0: now, dur: shot.t, to: shot.to, pay: shot.pay || 0, x: shot.path[0] / 2, y: shot.path[1] / 2 });
    sfx.shot();
  }

  function land(b, now) {
    b.done = true;
    if (b.to === 'miss') return;
    P.flash[b.to] = now + 200;
    if (b.to === 'attacker') P.gain += b.pay;
    (sfx[b.to] || sfx.heso)();
    if (b.pay > 0) sfx.payout(b.pay);
    P.lastPay = b.pay;
    showNumbers();
  }

  function stepBall(b, now) {
    const t = now - b.t0;
    if (t >= b.dur) return land(b, now);
    const n = b.path.length / 2;
    // 軌道の 1 点目は打ってから SAMPLE_MS 後。最後の点は届いた位置
    const f = Math.max(0, t / SAMPLE_MS - 1);
    const i = Math.min(n - 1, Math.floor(f)), j = Math.min(n - 1, i + 1), k = f - Math.floor(f);
    b.x = (b.path[i * 2] + (b.path[j * 2] - b.path[i * 2]) * k) / 2;
    b.y = (b.path[i * 2 + 1] + (b.path[j * 2 + 1] - b.path[i * 2 + 1]) * k) / 2;
    // 釘に当たった点を通ったら音を鳴らし、風車の近くなら風車を回す
    while (b.hi < b.hits.length && b.hits[b.hi] <= i + 1) {
      b.hi++;
      sfx.nail(now);
      P.board.windmills.forEach((w, m) => { if (Math.hypot(b.x - w.x, b.y - w.y) < w.r + 14) P.mills[m].v = 22 * (b.x < w.x ? 1 : -1); });
    }
  }

  function drawBalls() {
    const r = P.board.ballR;
    for (const b of P.balls) {
      const g = ctx.createRadialGradient(b.x - 2.2, b.y - 2.2, 1, b.x, b.y, r);
      g.addColorStop(0, '#fff'); g.addColorStop(0.5, '#cfd2da'); g.addColorStop(1, '#5d6170');
      ctx.beginPath(); ctx.arc(b.x, b.y, r, 0, Math.PI * 2); ctx.fillStyle = g; ctx.fill();
    }
  }

  // =====================================================================
  // 液晶（図柄・予告・リーチ・花火）
  // =====================================================================
  const lcdCv = $('pLcdCv');
  const lcd = lcdCv.getContext('2d');
  const sparks = [];
  const stars = Array.from({ length: 40 }, () => ({ x: Math.random(), y: Math.random() * 0.6, r: rand(0.4, 1.2), p: rand(0, 6) }));
  const COLORS = ['#e8452c', '#f6d98a', '#7fb8ff', '#ffffff', '#ff9d8a', '#9dffb0'];
  const DIGIT_COLOR = (d) => (d % 2 ? '#ff7a63' : '#7fb8ff');

  function burst(x, y, n, color, power = 1) {
    const c = color || COLORS[Math.floor(Math.random() * COLORS.length)];
    for (let i = 0; i < n; i++) {
      const a = (Math.PI * 2 * i) / n + rand(-0.1, 0.1), v = rand(30, 100) * power;
      sparks.push({ x, y, vx: Math.cos(a) * v, vy: Math.sin(a) * v, life: rand(700, 1300), age: 0, c });
    }
  }
  function showCard(text, sub, ms, color) { P.card = { text, sub, until: performance.now() + ms, color: color || '#fff' }; }

  // 図柄の列。pos は「何番目の図柄がまん中にあるか」（小数。増えると図柄が上から下へ流れる）
  const digitAt = (i) => ((((Math.round(i) % 9) + 9) % 9) + 1);
  function newCols(d) { return d.map((n) => ({ pos: n - 1, state: 'stopped', v: 0 })); }
  // 列を、時刻 at に図柄 digit で止まるように、いまの位置から先の番号を決めて一定の速さで進める
  function aim(col, digit, now, at, minSpeed) {
    const left = Math.max(60, at - now) / 1000;
    let target = Math.ceil(col.pos + minSpeed * left);
    while (digitAt(target) !== digit) target++;
    col.state = 'aim'; col.target = target; col.v = (target - col.pos) / left; col.at = at;
  }

  // サーバーから変動が始まった知らせが来た。elapsed は、サーバーで始まってから過ぎた時間
  function startSpin(ev) {
    const D = ev.duration, stage = ev.stage || 'none';
    const reach = stage !== 'none';
    // 止まる時刻（左 → 右 → 中）。当たりは最後の 4 秒が祝い
    const tail = ev.hit ? 4000 : 500;
    const t1 = Math.min(900, D * 0.3), t2 = Math.min(1500, D * 0.5);
    const t3 = reach ? D - tail : Math.min(2300, D - 200);
    P.spin = {
      start: performance.now() - (ev.elapsed || 0), duration: D, stage, reach, hit: ev.hit, digits: ev.digits, yokoku: ev.yokoku || 0,
      t1, t2, t3, spAt: stage === 'sp' ? t2 + 2600 : null, phase: 0, done: false,
    };
    P.cols = P.cols || newCols(ev.digits);
    P.cols.forEach((c) => { c.state = 'roll'; c.v = 13; });
    P.card = null;
    if ((ev.elapsed || 0) < 600) {
      sfx.start();
      if (P.spin.yokoku > 0) {
        sfx.yokoku(P.spin.yokoku);
        showCard(['', 'チャンス', '熱', '激熱'][P.spin.yokoku], null, 900, ['', '#7fb8ff', '#ff7a63', '#f6d98a'][P.spin.yokoku]);
        burst(120, 40, 10 + P.spin.yokoku * 10, null, 0.8 + P.spin.yokoku * 0.3);
      }
    }
  }

  function stepSpin(now, dt) {
    const sp = P.spin, cols = P.cols;
    if (!cols) return;
    for (const c of cols) {
      if (c.state === 'roll') c.pos += c.v * dt / 1000;
      else if (c.state === 'aim') {
        c.pos += c.v * dt / 1000;
        if (now >= c.at || c.pos >= c.target) { c.pos = c.target; c.state = 'stopped'; if (sp && now - sp.start < sp.duration + 400) sfx.stop(); }
      }
    }
    if (!sp) return;
    const t = now - sp.start, at = (ms) => sp.start + ms;
    const [dl, dc, dr] = sp.digits;
    if (sp.stage === 'full') {
      // 全回転: 3 列が同じ図柄のまま、ゆっくり流れて揃って止まる
      if (sp.phase < 1 && t >= sp.t1) {
        sp.phase = 1;
        const base = Math.ceil(cols[0].pos);
        cols.forEach((c) => { c.pos = base; aim(c, dl, now, at(sp.t3), 1.6); });
        showCard('全回転', null, 1600, '#f6d98a');
        sfx.sp(); setTune('sp');
      }
    } else {
      if (sp.phase < 1 && t >= sp.t1) { sp.phase = 1; aim(cols[0], dl, now, at(sp.t1 + 260), 8); }
      if (sp.phase < 2 && t >= sp.t2) {
        sp.phase = 2;
        aim(cols[2], dr, now, at(sp.t2 + 260), 8);
        // リーチなら、中の列はゆっくり流して最後に止める
        if (sp.reach) aim(cols[1], dc, now, at(sp.t3), sp.stage === 'sp' ? 1.3 : 2.2);
      }
      if (sp.reach && sp.phase < 3 && t >= sp.t2 + 320) {
        sp.phase = 3;
        if (t < sp.t3) { showCard('リーチ', null, 1300, '#f6d98a'); sfx.reach(); setTune('reach'); burst(rand(50, 190), rand(24, 60), 16); }
      }
      if (sp.spAt && sp.phase < 4 && t >= sp.spAt) {
        sp.phase = 4;
        if (t < sp.t3) { showCard('スーパーリーチ', null, 1700, '#ff7a63'); sfx.sp(); setTune('sp'); }
      }
      if (!sp.reach && sp.phase < 3 && t >= sp.t3) { sp.phase = 3; aim(cols[1], dc, now, at(sp.t3 + 260), 8); }
    }
    if (!sp.done && t >= sp.t3 + 280) {
      sp.done = true;
      setTune(null);
      if (sp.hit) {
        showCard('大当たり', dl % 2 ? '確変' : '通常', 3400, dl % 2 ? '#ff7a63' : '#7fb8ff');
        if (t < sp.duration + 400) sfx.hit();
        for (let i = 0; i < 6; i++) setTimeout(() => burst(rand(30, 210), rand(20, 80), 26, null, 1.3), i * 260);
      }
    }
    if (t >= sp.duration) { P.spin = null; cols.forEach((c, i) => { c.pos = sp.digits[i] - 1 + 9 * 1000; c.state = 'stopped'; }); }
  }

  function drawLcd(now, dt) {
    const B = P.board, W = B.lcd.w, H = B.lcd.h, info = P.info || {};
    const sp = P.spin, jp = info.jackpot;
    const mood = jp ? 'jackpot' : sp && sp.stage === 'full' && sp.phase >= 1 ? 'full' : sp && sp.phase >= 4 ? 'sp' : sp && sp.reach && sp.phase >= 3 ? 'reach' : info.mode || 'normal';

    // 空と川
    const g = lcd.createLinearGradient(0, 0, 0, H);
    const top = { normal: '#060a1e', reach: '#0d0a2a', sp: '#2a0a1a', full: '#2a2206', jackpot: '#1a0a2e', kakuhen: '#1f0810', jitan: '#06142a' }[mood] || '#060a1e';
    g.addColorStop(0, top); g.addColorStop(0.72, '#141c48'); g.addColorStop(0.73, '#0a1030'); g.addColorStop(1, '#05081a');
    lcd.fillStyle = g; lcd.fillRect(0, 0, W, H);
    for (const s of stars) {
      lcd.globalAlpha = 0.45 + 0.4 * Math.sin(now / 700 + s.p);
      lcd.fillStyle = '#fff';
      lcd.beginPath(); lcd.arc(s.x * W, s.y * H, s.r, 0, Math.PI * 2); lcd.fill();
    }
    lcd.globalAlpha = 1;
    // 対岸の街の明かり
    lcd.fillStyle = '#05060f';
    lcd.fillRect(0, H * 0.70, W, H * 0.035);
    for (let i = 0; i < 26; i++) {
      lcd.fillStyle = i % 3 ? 'rgba(246,217,138,.7)' : 'rgba(232,69,44,.7)';
      lcd.fillRect(6 + i * (W - 12) / 26, H * 0.705, 2, 2);
    }

    // 花火（状態に応じて上げる数を変える）
    const rate = { jackpot: 420, full: 260, sp: 380, reach: 900 }[mood];
    if (rate && now > (P.nextBurst || 0)) { P.nextBurst = now + rand(rate * 0.6, rate * 1.4); burst(rand(24, W - 24), rand(16, H * 0.45), 22, null, mood === 'reach' ? 0.8 : 1.2); }
    for (let i = sparks.length - 1; i >= 0; i--) {
      const p = sparks[i];
      p.age += dt;
      if (p.age >= p.life) { sparks.splice(i, 1); continue; }
      const s = dt / 1000;
      p.vy += 50 * s; p.vx *= 1 - 1.3 * s; p.vy *= 1 - 1.3 * s;
      p.x += p.vx * s; p.y += p.vy * s;
      lcd.globalAlpha = 1 - p.age / p.life;
      lcd.fillStyle = p.c;
      lcd.beginPath(); lcd.arc(p.x, p.y, 1.7, 0, Math.PI * 2); lcd.fill();
      // 川に映る
      lcd.globalAlpha *= 0.25;
      lcd.fillRect(p.x - 0.8, H * 0.74 + (H * 0.72 - p.y) * 0.25, 1.6, 2);
    }
    lcd.globalAlpha = 1;

    // 図柄（大当たり中は左上に小さく）
    if (P.cols) {
      const small = !!jp;
      const cw = small ? 22 : 62, ch = small ? 28 : 86, gap = small ? 4 : 10;
      const x0 = small ? 8 : (W - cw * 3 - gap * 2) / 2, y0 = small ? 6 : (H - ch) / 2 - 2;
      const win = sp && sp.hit && sp.done;
      P.cols.forEach((c, i) => {
        const x = x0 + i * (cw + gap);
        lcd.save();
        lcd.beginPath(); lcd.rect(x, y0, cw, ch); lcd.clip();
        lcd.fillStyle = 'rgba(5, 6, 15, .62)'; lcd.fillRect(x, y0, cw, ch);
        const base = Math.floor(c.pos), frac = c.pos - base;
        const fast = c.state === 'roll';
        for (let k = -1; k <= 1; k++) {
          const d = digitAt(base + k + (frac > 0.5 ? 1 : 0));
          const off = (k + (frac > 0.5 ? 1 : 0)) - frac; // まん中からのずれ（図柄 1 つ分が 1）
          lcd.globalAlpha = fast ? 0.5 : 1;
          lcd.font = `800 ${Math.round(ch * 0.78)}px 'Yu Gothic UI', 'Meiryo', sans-serif`;
          lcd.textAlign = 'center'; lcd.textBaseline = 'middle';
          lcd.fillStyle = fast ? '#cfd2e8' : DIGIT_COLOR(d);
          // 増える向き（off が負）が下。上から下へ流れる
          lcd.fillText(String(d), x + cw / 2, y0 + ch / 2 - off * ch + 2);
        }
        lcd.restore();
        lcd.globalAlpha = 1;
        lcd.lineWidth = win ? 3 : 1.5;
        lcd.strokeStyle = win ? `rgba(246,217,138,${0.6 + 0.4 * Math.sin(now / 90)})` : 'rgba(246,217,138,.5)';
        lcd.strokeRect(x, y0, cw, ch);
      });
    }

    // 大当たり中: ラウンドと入った数、もらった玉
    if (jp) {
      lcd.textAlign = 'center'; lcd.textBaseline = 'middle';
      lcd.font = "800 26px Consolas, monospace"; lcd.fillStyle = '#f6d98a';
      lcd.fillText(`ROUND ${jp.round} / ${jp.rounds}`, W / 2, H * 0.36);
      const n = P.roundCount, r = 6, gap = 5, tw = n * r * 2 + (n - 1) * gap;
      for (let i = 0; i < n; i++) {
        lcd.beginPath(); lcd.arc(W / 2 - tw / 2 + r + i * (r * 2 + gap), H * 0.56, r, 0, Math.PI * 2);
        lcd.fillStyle = i < jp.count ? '#e6e8ef' : '#2a2440'; lcd.fill();
        lcd.lineWidth = 1; lcd.strokeStyle = '#5a4a80'; lcd.stroke();
      }
      lcd.font = "800 22px Consolas, monospace"; lcd.fillStyle = '#fff';
      lcd.fillText(`+${fmt(P.gain)}`, W / 2, H * 0.84);
      lcd.font = "700 11px 'Yu Gothic UI', sans-serif"; lcd.fillStyle = jp.open ? '#f6d98a' : '#8a84a0';
      lcd.fillText(jp.open ? 'アタッカー開放中' : '準備中', W - 46, 16);
    }

    // 大きな文字（予告・リーチ・大当たり・確変突入）
    const card = P.card;
    if (card && now < card.until) {
      const left = card.until - now;
      const a = Math.min(1, left / 250);
      lcd.globalAlpha = a;
      lcd.fillStyle = 'rgba(5,6,15,.55)';
      const big = card.text.length <= 4;
      const y = jp ? H * 0.5 : (sp && !sp.done ? H - 20 : H * 0.5);
      const bh = sp && !sp.done && !jp ? 26 : 62;
      lcd.fillRect(0, y - bh / 2, W, bh);
      lcd.textAlign = 'center'; lcd.textBaseline = 'middle';
      lcd.font = `800 ${bh === 26 ? 17 : (big ? 40 : 28)}px 'Yu Gothic UI', 'Meiryo', sans-serif`;
      lcd.fillStyle = card.color;
      lcd.fillText(card.text, W / 2, y + (card.sub && bh > 26 ? -8 : 1));
      if (card.sub && bh > 26) { lcd.font = "700 14px 'Yu Gothic UI', sans-serif"; lcd.fillStyle = '#fff'; lcd.fillText(card.sub, W / 2, y + 20); }
      lcd.globalAlpha = 1;
    }

    // 確変・時短の帯
    if (!jp && info.mode && info.mode !== 'normal' && !(sp && sp.reach && sp.phase >= 3)) {
      lcd.font = "800 12px 'Yu Gothic UI', sans-serif"; lcd.textAlign = 'left'; lcd.textBaseline = 'middle';
      lcd.fillStyle = info.mode === 'kakuhen' ? '#ff7a63' : '#7fb8ff';
      lcd.fillText(info.mode === 'kakuhen' ? '確変中' : `時短 残り ${info.jitanLeft}`, 8, 12);
    }
  }

  // =====================================================================
  // 数字と表示
  // =====================================================================
  // 持ち玉は、飛んでいる玉が画面で届いてから増やして見せる
  //   サーバーの「持ち玉 + まだ届いていない賞球」から、画面でまだ飛んでいる玉の賞球を引く
  function showNumbers() {
    const info = P.info;
    if (!info) return;
    const local = P.balls.reduce((n, b) => n + (b.done ? 0 : b.pay), 0);
    const balls = Math.max(0, info.balls + (info.inflight || 0) - local);
    $('pBalls').textContent = fmt(balls);
    $('pBallsYen').textContent = `${fmt(balls * P.price)}円`;
    $('pTrayBalls').style.height = `${Math.min(44, Math.ceil(balls / 12) * 2)}px`;
    $('pPay').textContent = fmt(info.jackpot ? P.gain : P.lastPay);
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

    // 保留（色は先読み。白・緑・赤）
    const holds = info.holds || [];
    Array.from($('pHold').children).forEach((el, i) => { el.className = i < holds.length ? `on ${holds[i]}` : ''; });

    if (jp && (!before || !before.jackpot)) { P.gain = 0; P.card = null; setTune('jackpot'); }
    else if (jp && before.jackpot && before.jackpot.round !== jp.round) sfx.round();
    if (!jp && !P.spin) setTune(info.mode === 'kakuhen' ? 'kakuhen' : null);
    showNumbers();
    checkStroke();

    const shown = !$('pachiAdmin').classList.contains('hidden');
    if (window.PachiAdminPanel && window.PachiAdminPanel.render(info) !== shown) layout();
  }

  // 打つ向きが状態に合っていないときに知らせる（本物の台も「右打ちしてください」「左打ちに戻してください」と言う）
  let warnAt = 0;
  function checkStroke() {
    const info = P.info, el = $('pWarn');
    if (!info) return;
    const wantRight = !!info.jackpot || info.mode !== 'normal';
    const isRight = P.power >= RIGHT_FROM;
    const text = wantRight && !isRight ? '右打ちしてください ▶' : (!wantRight && isRight ? '◀ 左打ちに戻してください' : '');
    el.textContent = text;
    el.classList.toggle('hidden', !text);
    if (text && P.firing && performance.now() > warnAt) { warnAt = performance.now() + 2600; sfx.warn(); }
  }

  // ---- ハンドル ----
  let powerTimer = null;
  function setPower(v, quiet) {
    P.power = clamp(Math.round(v), 0, 100);
    if (P.power < RIGHT_FROM) P.leftPower = P.power;
    $('pPowerNum').textContent = P.power;
    $('pPowerBar').style.width = `${P.power}%`;
    $('pHandle').style.setProperty('--turn', `${-50 + P.power * 2.1}deg`);
    try { localStorage.setItem('ta-arcade-pachi-power', String(P.leftPower)); } catch (e) { /* 覚えられなくても続ける */ }
    checkStroke();
    if (quiet) return;
    // 回している間は、まとめて 1 回だけ Lua へ伝える
    clearTimeout(powerTimer);
    powerTimer = setTimeout(() => post('pachi:power', { power: P.power }), 80);
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

  // ---- サーバーの返事（1発ごと、または続き） ----
  function onTick(d) {
    if (!P.open) return;
    if (typeof d.firing === 'boolean' && d.firing !== P.firing) setFiring(d.firing);
    if (d.lent) toast(`${fmt(d.lent)}円で ${P.lend}玉を借りました`);
    if (d.shot) launch(d.shot, performance.now());
    for (const ev of d.events || []) {
      if (ev.t === 'spin') startSpin(ev);
      else if (ev.t === 'jackpotEnd') {
        setTune(null); sfx.end();
        showCard(ev.mode === 'kakuhen' ? '確変突入' : `時短 ${P.jitan}回`, ev.mode === 'kakuhen' ? '次の大当たりまで右打ち' : '右打ちのまま', 2800, ev.mode === 'kakuhen' ? '#ff7a63' : '#7fb8ff');
      } else if (ev.t === 'jitanEnd') {
        toast('時短が終わりました。左打ちに戻してください');
      }
    }
    applyInfo(d.info);
  }

  // ---- 描く ----
  let last = 0;
  function frame(now) {
    if (!P.open) return;
    const dt = Math.min(50, now - (last || now));
    last = now;
    for (const b of P.balls) if (!b.done) stepBall(b, now);
    if (P.balls.some((b) => b.done)) { P.balls = P.balls.filter((b) => !b.done); showNumbers(); }
    stepSpin(now, dt);

    const B = P.board;
    ctx.clearRect(0, 0, B.W, B.H);
    ctx.drawImage(bg, 0, 0, B.W, B.H);
    drawParts(now, dt);
    drawBalls();
    drawLcd(now, dt);
    requestAnimationFrame(frame);
  }

  // =====================================================================
  // Lua から・キー
  // =====================================================================
  function open(d) {
    P.board = d.board;
    P.price = d.price; P.lend = d.lend; P.interval = d.interval;
    P.roundCount = d.roundCount; P.jitan = d.jitan; P.userScale = d.scale || 1;
    if (d.pay) P.pay = d.pay;
    $('pRate').textContent = `${fmt(d.price)}円 / 玉`;
    $('pLend').textContent = d.lend;
    $('pJitan').textContent = d.jitan;
    P.balls = []; P.spin = null; P.gain = 0; P.lastPay = 0; P.info = null; P.card = null;
    P.mills = P.board.windmills.map(() => ({ a: 0, v: 1.2 }));
    P.cols = newCols([7, 3, 5]);
    P.open = true;
    $('pachiStage').classList.remove('hidden');
    // ハンドルは前に合わせた左打ちの強さから始める（Lua 側は 0 から始まるので伝える）
    let saved = 32;
    try { saved = parseInt(localStorage.getItem('ta-arcade-pachi-power'), 10); } catch (e) { /* 既定のまま */ }
    setPower(Number.isFinite(saved) ? clamp(saved, 0, RIGHT_FROM - 1) : 32);
    setFiring(false);
    layout();
    if (d.info.spin) startSpin(d.info.spin); // 前の人の変動が残っていた
    applyInfo(d.info);
    last = 0;
    requestAnimationFrame(frame);
  }
  function close() {
    P.open = false;
    P.firing = false;
    setTune(null);
    $('pachiStage').classList.add('hidden');
    $('pachiData').classList.add('hidden');
  }
  function toggleFire() {
    const on = !P.firing;
    setFiring(on);
    post('pachi:fire', { on, power: P.power }).then((res) => { if (!res || !res.ok) setFiring(false); });
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
  // ホイールでもハンドルを回せる
  window.addEventListener('wheel', (e) => { if (P.open) setPower(P.power + (e.deltaY < 0 ? 1 : -1)); }, { passive: true });

  window.addEventListener('keydown', (e) => {
    if (!$('pachiData').classList.contains('hidden')) {
      if (e.key === 'Escape' || e.key === 'Backspace' || e.key === 'Enter') { e.preventDefault(); closeData(); }
      return;
    }
    if (!P.open) return;
    const step = e.shiftKey ? 5 : 1;
    // ハンドルは押しっぱなしでも回る。ほかのキーは押した時だけ
    switch (e.key) {
      case 'ArrowLeft': case 'a': case 'A': e.preventDefault(); return setPower(P.power - step);
      case 'ArrowRight': case 'd': case 'D': e.preventDefault(); return setPower(P.power + step);
    }
    if (e.repeat) return;
    switch (e.key) {
      case ' ': case 'Enter': e.preventDefault(); toggleFire(); break;
      case 'ArrowUp': case 'w': case 'W': e.preventDefault(); setPower(RIGHT_POWER); break;
      case 'ArrowDown': case 's': case 'S': e.preventDefault(); setPower(P.leftPower); break;
      case 'm': case 'M': P.muted = !P.muted; if (P.muted) setTune(null); toast(P.muted ? '音を消しました' : '音を出します'); break;
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
  //   玉の軌道は、サーバーの物理計算で前もって出したもの（design/pachi_sample.js。tests/pachi-export.lua が作る）から選ぶ
  //   &pachi=kakuhen / jitan / jackpot で状態、&hit で次の変動が当たり、&fire で打ち始める、&power=NN でハンドルの強さ、
  //   &pachiadmin で管理パネル、&pachidata でデータ表示
  // 見やすいよう、当たる割合は本物より高くしてある
  // =====================================================================
  const Mock = {
    balls: 240, cash: 15230000, mode: 'normal', jitanLeft: 0, queue: [], flying: [], spin: null, jackpot: null, freeAt: 0,
    data: { total: 1234, kakuhen: 4, normal: 3, since: 87, history: [{ t: 'kakuhen', g: 212, r: 10 }, { t: 'normal', g: 54, r: 4 }, { t: 'kakuhen', g: 388, r: 4 }] },
    admin: null, firing: false, forceHit: false, power: 32,
    jpView(now) {
      const jp = this.jackpot;
      if (!jp) return null;
      return { kind: jp.kind, round: jp.round, rounds: jp.rounds, count: Math.min(P.roundCount, jp.arr.filter((t) => t <= now).length), open: now >= jp.openAt && !jp.closing };
    },
    info(now) {
      const sp = this.spin;
      return {
        id: 7, balls: this.balls, inflight: this.flying.reduce((n, b) => n + b.pay, 0), flying: this.flying.length, cash: this.cash,
        mode: this.mode, jitanLeft: this.jitanLeft, hold: this.queue.length, holds: this.queue.map((q) => q.hot),
        spin: sp ? { elapsed: now - sp.startAt, duration: sp.endAt - sp.startAt, stage: sp.stage, yokoku: sp.yokoku, hit: !!sp.hit, digits: sp.digits } : null,
        jackpot: this.jpView(now), data: this.data, admin: this.admin,
      };
    },
    advance(now, events) {
      // 届いた玉
      this.flying = this.flying.filter((b) => {
        if (b.at > now) return true;
        this.balls += b.pay;
        if ((b.to === 'heso' || b.to === 'denchu') && this.queue.length < 4) {
          const hit = this.forceHit || Math.random() < (this.mode === 'kakuhen' ? 1 / 5 : 1 / 14);
          this.forceHit = false;
          this.queue.push({ at: b.at, hit, hot: hit ? (Math.random() < 0.5 ? 'red' : 'green') : (Math.random() < 0.06 ? 'green' : 'white') });
        }
        if (b.to === 'attacker' && this.jackpot) {
          const jp = this.jackpot;
          jp.arr.push(b.at);
          if (jp.arr.length >= P.roundCount) {
            if (jp.round >= jp.rounds) {
              this.jackpot = null;
              this.mode = jp.kind === 'kakuhen' ? 'kakuhen' : 'jitan';
              this.jitanLeft = this.mode === 'jitan' ? P.jitan : 0;
              this.freeAt = now + 2500;
              events.push({ t: 'jackpotEnd', mode: this.mode });
            } else { jp.round++; jp.arr = []; jp.openAt = now + 1200; }
          }
        }
        return false;
      });
      while (!this.jackpot) {
        const sp = this.spin;
        if (sp) {
          if (now < sp.endAt) break;
          this.spin = null; this.freeAt = sp.endAt;
          this.data.total++; this.data.since++;
          if (sp.hit) {
            this.jackpot = { kind: sp.hit, rounds: sp.rounds, round: 1, arr: [], openAt: sp.endAt + 2500 };
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
          const hit = q.hit ? (Math.random() < 0.5 ? 'kakuhen' : 'normal') : null;
          const want = Q.get('stage');
          const stage = hit ? (want || (Math.random() < 0.1 ? 'full' : Math.random() < 0.6 ? 'sp' : 'reach')) : (Math.random() < 0.18 ? (Math.random() < 0.3 ? 'sp' : 'reach') : 'none');
          const base = { none: support ? 1800 : (this.queue.length >= 2 ? 3500 : 6000), reach: support ? 6000 : 12000, sp: support ? 13000 : 26000, full: support ? 10000 : 18000 }[stage];
          const dur = base + (hit && stage !== 'none' ? 4000 : 0);
          const a = 1 + Math.floor(Math.random() * 9);
          const digits = hit === 'kakuhen' ? [7, 7, 7] : hit === 'normal' ? [4, 4, 4] : stage !== 'none' ? [a, a % 9 + 1, a] : [a, 1 + Math.floor(Math.random() * 9), a % 9 + 1];
          const yokoku = hit ? 1 + Math.floor(Math.random() * 3) : (Math.random() < 0.15 ? 1 : 0);
          this.spin = { startAt: t0, endAt: t0 + dur, hit, stage, yokoku, rounds: hit ? (Math.random() < 0.7 ? 4 : 10) : null, digits };
          events.push({ t: 'spin', elapsed: now - t0, duration: dur, stage, yokoku, hit: !!hit, digits, hot: q.hot });
        }
      }
    },
    // 物理計算で出してある軌道から、いまの状態とハンドルの強さに合うものを選ぶ
    shoot(now) {
      const S = window.PACHI_SAMPLE;
      const jp = this.jackpot;
      const cond = jp && now + 1200 >= jp.openAt ? 'jackpot' : (this.mode !== 'normal' && !jp ? 'support' : 'normal');
      const pool = cond === 'normal' ? S.normal.concat(S.aim) : S[cond].concat(S.normal);
      let near = pool.filter((s) => Math.abs(s.power - this.power) <= 3);
      for (let w = 6; !near.length; w += 4) near = pool.filter((s) => Math.abs(s.power - this.power) <= w);
      const s = near[Math.floor(Math.random() * near.length)];
      const pay = P.pay[s.to] || 0;
      this.flying.push({ at: now + s.t, to: s.to, pay });
      return { to: s.to, t: s.t, pay, path: s.path, hits: s.hits };
    },
    tick() {
      const now = performance.now();
      const events = [];
      this.advance(now, events);
      let shot = null, lent = null;
      if (this.firing) {
        if (this.balls < 1) { this.balls += P.lend; this.cash -= P.lend * P.price; lent = P.lend * P.price; }
        this.balls--;
        shot = this.shoot(now);
      } else if (!events.length && !this.spin && !this.queue.length && !this.flying.length) return;
      window.postMessage({ action: 'pachi:tick', shot, events, lent, info: this.info(now), firing: this.firing }, '*');
    },
    post(name, d) {
      if (name === 'pachi:fire') { this.firing = d.on; this.power = d.power; return { ok: true, on: d.on }; }
      if (name === 'pachi:power') { this.power = d.power; return { ok: true }; }
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
    if (want === 'jackpot') Mock.jackpot = { kind: 'kakuhen', rounds: 10, round: 3, arr: [0, 0, 0, 0], openAt: 0 };
    if (Q.has('hit')) Mock.forceHit = true;
    if (Q.has('pachiadmin')) Mock.admin = { setting: 4, force: Q.get('pachiadmin') || null };
    const begin = () => {
      if (Q.has('pachidata')) return openData({ id: 7, data: Mock.data });
      try { localStorage.removeItem('ta-arcade-pachi-power'); } catch (e) { /* 無くてもよい */ }
      open({ info: Mock.info(performance.now()), board: window.PACHI_SAMPLE.board, price: 20000, lend: 25, maxBalls: 2500, interval: 600, roundCount: 9, jitan: 100, scale: 1 });
      if (Q.get('power')) setPower(+Q.get('power'));
      else if (want && want !== '') setPower(RIGHT_POWER);
      Mock.power = P.power;
      setInterval(() => Mock.tick(), P.interval);
      if (Q.has('fire')) toggleFire();
    };
    // 盤面と軌道の見本を読む（リソースには入れない。design/ にある）
    const s = document.createElement('script');
    s.src = '../design/pachi_sample.js';
    s.onload = begin;
    s.onerror = () => { document.body.insertAdjacentHTML('beforeend', '<p style="position:fixed;left:20px;top:20px;color:#fff">design/pachi_sample.js がありません。tests/ で node lua-run.js pachi-export.lua sample &gt; ../design/pachi_sample.js を実行してください</p>'); };
    document.head.appendChild(s);
  }
})();
