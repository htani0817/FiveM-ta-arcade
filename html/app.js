// ta-arcade のパチスロ「夜祭」の画面。リールを回して、押した位置を Lua に渡し、止まる位置をもらって止める
(() => {
  'use strict';

  const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'ta-arcade';
  const PREVIEW = new URLSearchParams(location.search).has('preview');
  const $ = (id) => document.getElementById(id);

  // ---- 定数 ----
  const N = 21;              // 1 リールのコマ数
  const SPEED = 0.028;       // コマ / ミリ秒（約 80 回転 / 分）
  const ACCEL_MS = 260;      // 回り始めて定速になるまで
  const SYM_FILES = { R7: 'seven', LN: 'lantern', BR: 'bar', BL: 'bell', SK: 'suika', CH: 'cherry', RP: 'replay' };
  // ライン（行 0=上段 1=中段 2=下段）。engine.lua の Lines と同じ順
  const LINES = [[1, 1, 1], [0, 0, 0], [2, 2, 2], [0, 1, 2], [2, 1, 0]];

  // ---- 状態 ----
  const S = {
    open: false,
    reelsData: null,
    price: 100, bet: 3, maxCredit: 50, wait: 4100,
    info: null,
    phase: 'idle',           // idle / lever / spin / result / pay
    betIn: 0,
    lastStart: -1e9,
    queued: false,
    muted: false,
  };

  // ---- 図柄の画像 ----
  const images = {};
  for (const [k, f] of Object.entries(SYM_FILES)) {
    const im = new Image();
    im.src = `img/sym_${f}.png`;
    images[k] = im;
  }

  // ---- 通信 ----
  async function post(name, data = {}) {
    if (PREVIEW) return Mock[name] ? Mock[name](data) : { ok: true };
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
    if (S.muted) return;
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
    bet: () => { tone(990, 0.05); tone(1320, 0.05, 'square', 0.05, 0.05); },
    lever: () => { tone(110, 0.12, 'triangle', 0.18); tone(70, 0.18, 'sine', 0.2, 0.02); },
    stop: () => { tone(180, 0.05, 'square', 0.09); tone(90, 0.06, 'triangle', 0.12); },
    medal: () => tone(1500, 0.03, 'square', 0.035),
    replay: () => { tone(660, 0.08, 'sine', 0.08); tone(880, 0.1, 'sine', 0.08, 0.08); },
    lamp: () => { [523, 659, 784, 1047].forEach((f, i) => tone(f, 0.35, 'sine', 0.07, i * 0.07)); },
    bonus: () => { [392, 523, 659, 784, 659, 784, 1047].forEach((f, i) => tone(f, 0.22, 'triangle', 0.09, i * 0.13)); },
    deny: () => tone(140, 0.15, 'sawtooth', 0.05),
  };

  // ---- リール ----
  class Reel {
    constructor(index, canvas) {
      this.i = index;
      this.cv = canvas;
      this.ctx = canvas.getContext('2d');
      this.x = 0;              // 位置（巻き戻さない実数。整数で止まる）
      this.state = 'stopped';  // stopped / spin / waiting / stopping
      this.v = 0;
      this.startAt = 0;
      this.limit = null;       // 押した後、答えが来るまでこれ以上進まない
      this.target = null;
      this.bounce = 0;
      this.onStopped = null;
    }
    resize() {
      const r = this.cv.getBoundingClientRect();
      const dpr = Math.max(1, window.devicePixelRatio || 1) * scale();
      this.cv.width = Math.round(r.width / scale() * dpr);
      this.cv.height = Math.round(r.height / scale() * dpr);
    }
    strip() { return S.reelsData[this.i]; }
    sym(p) { return this.strip()[((p % N) + N) % N]; }
    start(now) { this.state = 'spin'; this.startAt = now; this.v = 0; this.limit = null; this.target = null; }
    ready(now) { return this.state === 'spin' && now - this.startAt >= ACCEL_MS; }
    // 押した。押した位置（滑り 0 で止まるコマ）は、答えを待つ間に通り過ぎないよう 1 コマ先にする
    press() {
      const p = Math.ceil(this.x) + 1;
      this.state = 'waiting';
      this.limit = p;
      return p;
    }
    stopAt(stop) {
      const p = this.limit;
      const d = ((stop - (p % N)) % N + N) % N; // 0〜4
      this.target = p + d;
      this.state = 'stopping';
    }
    snap(stop) { // サーバーの答えと違ったときに合わせる
      const base = Math.round(this.x);
      const d = ((stop - (base % N)) % N + N) % N;
      this.x = base + d;
      this.state = 'stopped';
      this.draw();
    }
    tick(now, dt) {
      if (this.state === 'stopped') { if (this.bounce > 0) { this.bounce = Math.max(0, this.bounce - dt / 90); this.draw(); } return; }
      const t = now - this.startAt;
      this.v = t < ACCEL_MS ? SPEED * (t / ACCEL_MS) : SPEED;
      let nx = this.x + this.v * dt;
      if (this.state === 'waiting' && nx >= this.limit) nx = this.limit;
      if (this.state === 'stopping' && nx >= this.target) {
        nx = this.target;
        this.state = 'stopped';
        this.bounce = 1;
        sfx.stop();
        const cb = this.onStopped; this.onStopped = null;
        if (cb) cb(((this.target % N) + N) % N);
      }
      this.x = nx;
      this.draw();
    }
    // 位置 x で 下段=floor(x) 中段=+1 上段=+2。x が増えると図柄は下へ流れる
    draw() {
      const c = this.ctx, W = this.cv.width, H = this.cv.height, rowH = H / 3;
      c.fillStyle = '#f4ecd6';
      c.fillRect(0, 0, W, H);
      const base = Math.floor(this.x);
      const frac = this.x - base;
      const off = this.bounce > 0 ? Math.sin(this.bounce * Math.PI) * rowH * 0.035 : 0;
      const blur = this.state !== 'stopped' && this.v > SPEED * 0.6;
      for (let k = -1; k <= 3; k++) {
        const sy = 2 * rowH - k * rowH + frac * rowH + off;
        const im = images[this.sym(base + k)];
        if (!im || !im.complete) continue;
        const w = W * 0.86, h = w * 0.75;
        const dx = (W - w) / 2, dy = sy + (rowH - h) / 2;
        if (blur) {
          c.globalAlpha = 0.35; c.drawImage(im, dx, dy - rowH * 0.18, w, h);
          c.globalAlpha = 0.35; c.drawImage(im, dx, dy + rowH * 0.18, w, h);
          c.globalAlpha = 0.55; c.drawImage(im, dx, dy, w, h);
          c.globalAlpha = 1;
        } else {
          c.drawImage(im, dx, dy, w, h);
        }
      }
      // 円筒に見せる陰
      const g = c.createLinearGradient(0, 0, 0, H);
      g.addColorStop(0, 'rgba(40,25,10,.45)'); g.addColorStop(.18, 'rgba(40,25,10,0)');
      g.addColorStop(.82, 'rgba(40,25,10,0)'); g.addColorStop(1, 'rgba(40,25,10,.45)');
      c.fillStyle = g; c.fillRect(0, 0, W, H);
    }
  }

  const reels = [new Reel(0, $('reel1')), new Reel(1, $('reel2')), new Reel(2, $('reel3'))];
  const stopBtns = [...document.querySelectorAll('.stop')];
  let stops = [null, null, null];

  let last = performance.now();
  function frame(now) {
    const dt = Math.min(50, now - last);
    last = now;
    if (S.open) {
      for (const r of reels) r.tick(now, dt);
      stopBtns.forEach((b, i) => b.classList.toggle('ready', S.phase === 'spin' && reels[i].ready(now)));
    }
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);

  // ---- 表示 ----
  const fmt = (n) => Math.floor(n || 0).toLocaleString('ja-JP');
  function setState(text, cls = '') {
    const el = $('state');
    el.className = 'state ' + cls;
    $('stateText').innerHTML = text || '&nbsp;';
  }
  function setLamp(on, withSound) {
    const was = $('lamp').classList.contains('on');
    $('lamp').classList.toggle('on', !!on);
    $('lampImg').src = on ? 'img/lamp_on.png' : 'img/lamp_off.png';
    if (on && !was && withSound) sfx.lamp();
  }
  function setBet(n) {
    S.betIn = n;
    for (let i = 1; i <= 3; i++) $('bet' + i).classList.toggle('on', i <= n);
  }
  function historyHtml(list) {
    if (!list || !list.length) return '<li class="none">まだありません</li>';
    return list.map((h, i) => `<li><span>${i + 1}</span><span class="${h.t === 'big' ? 'b' : 'r'}">${h.t === 'big' ? 'BIG' : 'REG'}</span><span>${fmt(h.g)} G</span></li>`).join('');
  }
  function applyInfo(info, opts = {}) {
    if (!info) return;
    S.info = info;
    $('credit').textContent = info.credit;
    $('creditYen').textContent = fmt(info.credit * S.price) + '円';
    $('cash').textContent = fmt(info.cash) + '円';
    $('cSince').textContent = fmt(info.data.since);
    $('cBig').textContent = fmt(info.data.big);
    $('cReg').textContent = fmt(info.data.reg);
    $('cTotal').textContent = fmt(info.data.total);
    $('history').innerHTML = historyHtml(info.data.history);
    if (!opts.keepLamp) setLamp(info.lamp, opts.lampSound);
    // 管理者なら台の横に管理パネル（admin.js）
    if (window.SlotAdminPanel) {
      const shown = !$('slotAdmin').classList.contains('hidden');
      if (window.SlotAdminPanel.render(info) !== shown) layout();
    }
    const bonus = info.mode !== 'normal';
    $('bonusRow').classList.toggle('hidden', !bonus);
    if (bonus) {
      $('bonusLabel').textContent = info.mode === 'big' ? 'BIG 中' : 'REG 中';
      $('bonusLeft').textContent = `残り ${Math.max(0, info.endPay - info.bonusPay)}枚`;
    }
    if (S.phase === 'idle') idleState();
  }
  function idleState() {
    const info = S.info;
    if (!info) return;
    if (info.mode !== 'normal') {
      setState(`${info.mode === 'big' ? 'BIG' : 'REG'}<br>残り ${Math.max(0, info.endPay - info.bonusPay)}枚`, 'bonus');
    } else if (info.replay) {
      setState('REPLAY', 'replay');
    } else {
      setState(info.credit >= S.bet ? 'BET してください' : `現金で ${fmt(S.bet * S.price)}円`);
    }
    $('maxbet').disabled = !(S.phase === 'idle');
  }
  let toastTimer = null;
  function toast(text) {
    const el = $('toast');
    el.textContent = text;
    el.classList.remove('hidden');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.add('hidden'), 2600);
  }

  // 揃ったラインを光らせる
  function showLines(pos) {
    const svg = $('paylines');
    svg.innerHTML = '';
    document.querySelectorAll('.lines i').forEach((i) => i.classList.remove('on'));
    if (!pos) return;
    const sym = (r, row) => S.reelsData[r][(pos[r] + (2 - row)) % N];
    const combos = { RP: ['RP', 'RP', 'RP'], BL: ['BL', 'BL', 'BL'], SK: ['SK', 'SK', 'SK'], R7: ['R7', 'R7', 'R7'], LN: ['LN', 'LN', 'LN'] };
    LINES.forEach((line, li) => {
      const s = [sym(0, line[0]), sym(1, line[1]), sym(2, line[2])];
      let hit = Object.values(combos).some((c) => c.every((x, i) => x === s[i]));
      if (!hit && s[0] === 'CH') hit = true;
      if (!hit) return;
      const y = (row) => 60 + row * 120;
      const el = document.createElementNS('http://www.w3.org/2000/svg', 'line');
      el.setAttribute('x1', 10); el.setAttribute('y1', y(line[0]));
      el.setAttribute('x2', 470); el.setAttribute('y2', y(line[2]));
      svg.appendChild(el);
      if (line[0] === line[2]) {
        document.querySelectorAll(`.lines i[data-l="${li + 1}"]`).forEach((i) => i.classList.add('on'));
      }
    });
  }

  // ---- 遊ぶ ----
  function maxBet() {
    if (S.phase !== 'idle' || S.betIn === S.bet) return;
    setBet(S.bet);
    sfx.bet();
  }

  async function lever() {
    if (S.phase !== 'idle') return;
    if (S.betIn < S.bet) { setBet(S.bet); sfx.bet(); }
    S.phase = 'lever';
    $('lever').classList.add('down');
    setTimeout(() => $('lever').classList.remove('down'), 160);
    showLines(null);
    $('pay').textContent = '0';

    // 4.1 秒たっていなければ待ってから回す
    const wait = S.wait - (performance.now() - S.lastStart);
    if (wait > 0) {
      setState('WAIT');
      await new Promise((r) => setTimeout(r, wait));
    }
    let res = await post('lever');
    if (!res.ok && res.reason === 'wait') {
      await new Promise((r) => setTimeout(r, Math.min(1500, res.wait + 30)));
      res = await post('lever');
    }
    if (!res.ok) {
      S.phase = 'idle';
      setBet(0);
      sfx.deny();
      toast(res.reason === 'wait' ? '少し待ってください' : (res.reason || 'レバーを叩けませんでした'));
      idleState();
      return;
    }
    sfx.lever();
    applyInfo(res.info, { keepLamp: true });
    if (res.info.lamp && !$('lamp').classList.contains('on')) setLamp(true, true); // 先告知
    S.lastStart = performance.now();
    stops = [null, null, null];
    const now = performance.now();
    reels.forEach((r) => r.start(now));
    S.phase = 'spin';
    setState(res.info.mode !== 'normal' ? `${res.info.mode === 'big' ? 'BIG' : 'REG'}<br>残り ${Math.max(0, res.info.endPay - res.info.bonusPay)}枚` : '&nbsp;', res.info.mode !== 'normal' ? 'bonus' : '');
  }

  async function stopReel(i) {
    if (S.phase !== 'spin') return;
    const r = reels[i];
    if (!r.ready(performance.now())) return;
    const press = r.press();
    stopBtns[i].classList.add('pressed');
    setTimeout(() => stopBtns[i].classList.remove('pressed'), 120);
    const res = await post('press', { reel: i + 1, press: ((press % N) + N) % N });
    const stop = res && res.ok ? res.stop : ((press % N) + N) % N;
    r.onStopped = (p) => {
      stops[i] = p;
      if (stops.every((s) => s !== null)) finish();
    };
    r.stopAt(stop);
  }

  async function finish() {
    S.phase = 'result';
    const res = await post('result');
    if (!res || !res.ok) {
      S.phase = 'idle';
      setBet(0);
      toast((res && res.reason) || '結果を受け取れませんでした');
      idleState();
      return;
    }
    // サーバーの止め方と違えば合わせる
    // Lua の { [1]=, [2]=, [3]= } は JSON では配列（0 始まり）で届く
    const sv = !res.stops ? null : Array.isArray(res.stops) ? res.stops : [res.stops[1], res.stops[2], res.stops[3]];
    if (sv) sv.forEach((p, i) => { if (p !== undefined && p !== stops[i]) reels[i].snap(p); });
    const pos = sv || stops;
    if (res.got) showLines(pos);
    setBet(0);

    // 払い出し（1 枚ずつ数える）
    S.phase = 'pay';
    const credit0 = S.info ? S.info.credit : 0;
    for (let k = 1; k <= res.pay; k++) {
      $('pay').textContent = k;
      $('credit').textContent = Math.min(S.maxCredit, credit0 + k);
      sfx.medal();
      await new Promise((r) => setTimeout(r, 45));
    }
    if (res.got === 'replay') sfx.replay();
    if (res.started) {
      sfx.bonus();
      toast(res.started === 'big' ? 'BIG BONUS!' : 'REGULAR BONUS');
    }
    const wasBonus = S.info && S.info.mode !== 'normal';
    S.phase = 'idle';
    applyInfo(res.info, { lampSound: true });
    if (wasBonus && res.info.mode === 'normal') toast('ボーナス終了');
    if (res.info.replay) { setBet(S.bet); }
    idleState();
  }

  async function leave() {
    if (S.phase !== 'idle') { toast('リールが止まってから精算できます'); return; }
    S.open = false;
    $('stage').classList.add('hidden');
    await post('leave');
  }

  // ---- 入力 ----
  $('lever').addEventListener('click', lever);
  $('maxbet').addEventListener('click', maxBet);
  $('payoutBtn').addEventListener('click', leave);
  stopBtns.forEach((b, i) => b.addEventListener('click', () => stopReel(i)));
  $('dvClose').addEventListener('click', closeData);

  window.addEventListener('keydown', (e) => {
    if (!$('dataview').classList.contains('hidden')) {
      if (e.key === 'Escape' || e.key === 'Backspace') closeData();
      return;
    }
    if (!S.open || e.repeat) return;
    switch (e.key) {
      case ' ': case 'Enter': case 'ArrowUp': e.preventDefault(); lever(); break;
      case 'ArrowLeft': case '1': case 'z': case 'Z': stopReel(0); break;
      case 'ArrowDown': case '2': case 'x': case 'X': stopReel(1); break;
      case 'ArrowRight': case '3': case 'c': case 'C': stopReel(2); break;
      case 'b': case 'B': maxBet(); break;
      case 'm': case 'M': S.muted = !S.muted; toast(S.muted ? '音を消しました' : '音を出します'); break;
      case 'Escape': case 'Backspace': leave(); break;
    }
  });

  // ---- 大きさ ----
  let userScale = 1;
  function scale() {
    const w = $('scaler').offsetWidth || 928, h = 1100; // 管理パネルが出ると横に広がる
    return Math.min(innerHeight * 0.95 / h, innerWidth * 0.96 / w) * userScale;
  }
  function layout() {
    $('scaler').style.transform = `scale(${scale()})`;
    reels.forEach((r) => { r.resize(); r.draw(); });
  }
  window.addEventListener('resize', layout);

  // ---- Lua から ----
  function open(d) {
    S.reelsData = d.reels;
    S.price = d.price; S.bet = d.bet; S.maxCredit = d.maxCredit; S.wait = d.wait;
    userScale = d.scale || 1;
    $('rate').textContent = `${fmt(d.price)}円 / 枚`;
    $('bigEnd').textContent = d.bonus.big;
    $('regEnd').textContent = d.bonus.reg;
    // 配当表に円も出す（8枚 = 80万円 など）
    document.querySelectorAll('.paytable [data-m]').forEach((el) => {
      const m = +el.dataset.m;
      el.innerHTML = `${m}枚 <small>${fmt(m * d.price)}円</small>`;
    });
    S.open = true;
    S.phase = 'idle';
    setBet(0);
    showLines(null);
    $('pay').textContent = '0';
    $('stage').classList.remove('hidden');
    // 前の人が止めたままの見た目にする（位置はばらばら）
    reels.forEach((r, i) => { r.x = (i * 7 + 3); r.state = 'stopped'; });
    layout();
    applyInfo(d.info);
    if (d.info.replay) setBet(S.bet);
  }
  function close() {
    S.open = false;
    $('stage').classList.add('hidden');
    $('dataview').classList.add('hidden');
  }
  function openData(d) {
    const x = d.data;
    $('dvId').textContent = '#' + d.id;
    $('dvSince').textContent = fmt(x.since);
    $('dvBig').textContent = fmt(x.big);
    $('dvReg').textContent = fmt(x.reg);
    $('dvTotal').textContent = fmt(x.total);
    const b = x.big + x.reg;
    $('dvRate').textContent = b > 0
      ? `ボーナス合算 1/${(x.total / b).toFixed(1)}（BIG 1/${x.big ? (x.total / x.big).toFixed(1) : '-'}・REG 1/${x.reg ? (x.total / x.reg).toFixed(1) : '-'}）`
      : 'まだボーナスは出ていません';
    $('dvHist').innerHTML = historyHtml(x.history);
    $('dataview').classList.remove('hidden');
  }
  function closeData() {
    $('dataview').classList.add('hidden');
    post('closeData');
  }

  // ボタンをクリックした後にスペースで同じボタンが押されないよう、フォーカスを外す
  document.addEventListener('mouseup', () => { if (document.activeElement && document.activeElement.blur) document.activeElement.blur(); });

  window.SlotApp = { applyInfo: (info) => { if (S.phase === 'idle' || S.phase === 'spin') applyInfo(info, { keepLamp: true }); } };

  window.addEventListener('message', (e) => {
    const d = e.data || {};
    if (d.action === 'open') open(d);
    else if (d.action === 'close') close();
    else if (d.action === 'data') openData(d);
  });

  // ---- ブラウザで見るための見本（?preview） ----
  const Mock = {
    credit: 12, cash: 15230000, mode: 'normal', lamp: false, replay: false, bonusPay: 0,
    data: { total: 1234, big: 4, reg: 3, since: 87, history: [{ t: 'big', g: 212 }, { t: 'reg', g: 54 }, { t: 'big', g: 388 }, { t: 'big', g: 97 }] },
    admin: null,
    info() { return { id: 3, credit: this.credit, cash: this.cash, mode: this.mode, lamp: this.lamp, replay: this.replay, bonusPay: this.bonusPay, endPay: 252, data: this.data, admin: this.admin }; },
    lever() {
      if (this.credit >= 3) this.credit -= 3; else this.cash -= 300000;
      if (Math.random() < 0.08) this.lamp = true;
      return { ok: true, info: this.info() };
    },
    press(d) { return { ok: true, stop: d.press }; },
    result() {
      const pay = Math.random() < 0.2 ? 8 : 0;
      this.credit = Math.min(50, this.credit + pay);
      this.data.total++; this.data.since++;
      return { ok: true, pay, got: pay ? 'bell' : null, info: this.info() };
    },
  };
  if (PREVIEW) {
    const reelsData = [
      ['RP', 'BL', 'CH', 'BL', 'LN', 'RP', 'BL', 'SK', 'CH', 'LN', 'RP', 'BL', 'RP', 'BL', 'R7', 'CH', 'BR', 'RP', 'BL', 'R7', 'SK'],
      ['BR', 'BL', 'BR', 'SK', 'RP', 'R7', 'BL', 'LN', 'RP', 'SK', 'BL', 'BR', 'RP', 'BL', 'R7', 'LN', 'RP', 'SK', 'BL', 'CH', 'RP'],
      ['CH', 'RP', 'BR', 'BL', 'SK', 'R7', 'RP', 'LN', 'BL', 'BR', 'RP', 'SK', 'BL', 'RP', 'R7', 'BL', 'BR', 'RP', 'SK', 'LN', 'BL'],
    ];
    const q = new URLSearchParams(location.search);
    if (q.get('bg')) document.body.style.background = `url(${q.get('bg')}) center/cover`;
    if (q.has('lamp')) Mock.lamp = true;
    if (q.has('big')) { Mock.mode = 'big'; Mock.bonusPay = 105; }
    if (q.has('slotadmin')) Mock.admin = { setting: 4, carried: 'big', force: q.get('slotadmin') || null };
    window.addEventListener('load', () => {
      if (q.has('admin') || q.has('pachi')) return; // 管理画面の見本は admin.js、パチンコの見本は pachi.js が開く
      if (q.has('data')) openData({ id: 3, data: Mock.data });
      else open({ reels: reelsData, price: 100000, bet: 3, maxCredit: 50, wait: 4100, bonus: { big: 252, reg: 96 }, scale: 1, info: Mock.info() });
      // ?auto: レバーと停止を自動で押す（描画の確認用）
      if (q.has('auto')) {
        Mock.result = function () { this.credit += 8; return { ok: true, pay: 8, got: 'bell', stops: stops.slice(), info: this.info() }; };
        setTimeout(lever, 300);
        [900, 1150, 1400].forEach((t, i) => setTimeout(() => stopReel(i), t));
      }
    });
  }
})();
