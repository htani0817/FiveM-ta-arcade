// ta-arcade の管理画面（/arcadeadmin）と、打っている管理者の横に出る管理パネル
(() => {
  'use strict';

  const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'ta-arcade';
  const Q = new URLSearchParams(location.search);
  const PREVIEW = Q.has('preview');
  const $ = (id) => document.getElementById(id);
  const fmt = (n) => Math.floor(n || 0).toLocaleString('ja-JP');
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  // lucide の線画（16px・線幅 1.5）
  const ICON = {
    plus: '<path d="M5 12h14"/><path d="M12 5v14"/>',
    x: '<path d="M18 6 6 18"/><path d="m6 6 12 12"/>',
    pin: '<path d="M20 10c0 6-8 12-8 12s-8-6-8-12a8 8 0 0 1 16 0Z"/><circle cx="12" cy="10" r="3"/>',
    reset: '<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/>',
    trash: '<path d="M3 6h18"/><path d="M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6"/><path d="M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2"/><path d="M10 11v6"/><path d="M14 11v6"/>',
    refresh: '<path d="M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/>',
  };
  const icon = (n) => `<svg class="a-svg" viewBox="0 0 24 24" aria-hidden="true">${ICON[n]}</svg>`;

  async function post(name, data = {}) {
    if (PREVIEW) return Mock[name] ? Mock[name](data) : { ok: true };
    try {
      const r = await fetch(`https://${RES}/${name}`, { method: 'POST', headers: { 'Content-Type': 'application/json; charset=UTF-8' }, body: JSON.stringify(data) });
      return await r.json();
    } catch (e) {
      return { ok: false, reason: '通信に失敗しました' };
    }
  }

  const MODE = { normal: '通常', big: 'BIG 中', reg: 'REG 中' };

  // =====================================================================
  // 管理画面
  // =====================================================================
  const A = { open: false, machines: [], games: [], sel: null, view: 'detail', placeGame: null, placeSetting: 1, confirm: null, defaultSetting: 1, bonusEnd: { big: 252, reg: 96 } };
  let root = null, toastTimer = null, confirmTimer = null;

  // 窓の枠は最初に一度だけ作る。ボタンを押した時は中身（台数・一覧・右側）だけを差し替える。
  // 枠ごと作り直すと、開く時のアニメーションが毎回やり直しになり、一覧のスクロールも先頭に戻る
  function ensureRoot() {
    if (root) return root;
    root = document.createElement('div');
    root.id = 'admin';
    root.className = 'hidden';
    root.innerHTML = `
      <div class="a-win" role="dialog" aria-label="Arcade 管理">
        <header class="a-head">
          <span class="a-brand">Arcade<span>管理</span></span>
          <span class="a-spacer"></span>
          <button class="a-btn quiet" data-act="refresh" title="読み込み直す">${icon('refresh')}</button>
          <button class="a-btn quiet" data-act="close"><span class="a-key">Esc</span>閉じる</button>
        </header>
        <div class="a-body">
          <aside class="a-side">
            <div class="a-side-top">
              <span class="a-count">近い順 · <span class="a-num" data-part="count">0</span> 台</span>
              <button class="a-btn primary" data-act="place">${icon('plus')}台を置く</button>
            </div>
            <div class="a-list" data-part="list"></div>
          </aside>
          <main class="a-main" data-part="main"></main>
        </div>
      </div>
      <div class="a-toast hide" id="aToast"></div>`;
    document.body.appendChild(root);
    root.addEventListener('click', onClick);
    return root;
  }

  const part = (name) => root.querySelector(`[data-part="${name}"]`);

  function scaleWin() {
    const s = Math.min(innerWidth * 0.94 / 1200, innerHeight * 0.92 / 760, 1.6);
    const win = root && root.querySelector('.a-win');
    if (win) win.style.setProperty('--a-scale', s.toFixed(3));
  }
  window.addEventListener('resize', scaleWin);

  function selected() { return A.machines.find((m) => m.id === A.sel) || null; }

  function rowHtml(m) {
    const d = m.data || {};
    return `<button class="a-row${m.id === A.sel && A.view === 'detail' ? ' sel' : ''}" data-act="select" data-id="${m.id}">
      <i class="a-dot${m.lamp ? '' : ' off'}" title="${m.lamp ? 'ランプが灯っている' : ''}"></i>
      <span class="t"><span class="id">#${m.id}</span><span class="name">${esc(m.label)}</span></span>
      <span class="s">設定${m.setting}</span>
      <span class="m"><span class="a-num">${fmt(m.dist)} m</span><span class="a-num">BIG ${fmt(d.big)} · REG ${fmt(d.reg)}</span>${m.busy ? '<span class="busy">打っている人あり</span>' : ''}</span>
    </button>`;
  }

  function graphHtml(d) {
    const hist = (d.history || []).slice(0, 8).reverse(); // 古い順に左から
    const items = hist.map((h) => ({ cls: h.t === 'big' ? 'big' : 'reg', g: h.g }));
    items.push({ cls: 'now', g: d.since || 0 });
    const max = Math.max(200, ...items.map((i) => i.g));
    const bars = items.map((i) => `<div class="bar ${i.cls}"><i style="height:${Math.max(2, Math.round(i.g / max * 100))}%"></i><em>${fmt(i.g)}</em></div>`).join('');
    return `<div class="a-graph">
      <div class="cap"><span>ボーナス間の回転数</span><span class="a-num">${hist.length ? '古い順' : 'まだありません'}</span></div>
      <div class="bars">${bars}</div>
      <div class="legend"><span><i style="background:var(--a-shu)"></i>BIG</span><span><i style="background:#4a4540"></i>REG</span><span><i style="box-shadow:inset 0 0 0 1px var(--a-muted)"></i>現在</span></div>
    </div>`;
  }

  function rate(total, n) { return n > 0 ? `1/${(total / n).toFixed(1)}` : '—'; }

  function detailHtml(m) {
    if (!m) {
      return `<div class="a-empty">${A.machines.length ? '左の一覧から台を選んでください' : 'まだ台がありません。「台を置く」から、見ている場所に台と椅子を置けます'}</div>`;
    }
    const d = m.data || {};
    const st = m.state || {};
    const game = A.games.find((g) => g.name === m.game);
    const confirmRemove = A.confirm === 'remove:' + m.id;
    const confirmReset = A.confirm === 'reset:' + m.id;
    const left = st.mode && st.mode !== 'normal' ? `（あと ${fmt(Math.max(0, (A.bonusEnd[st.mode] || 0) - (st.bonusPay || 0)))} 枚）` : '';
    return `
      <div>
        <div class="a-title"><h2>${esc(m.label)}</h2><span class="id">#${m.id}</span></div>
        <div class="a-meta">
          <span>${m.busy ? '打っている人: ' + esc(m.seatName || 'あり') : '空き'}</span>
          <span class="a-num">${fmt(m.dist)} m 先</span>
          <span class="a-num">${m.x.toFixed(1)}, ${m.y.toFixed(1)}, ${m.z.toFixed(1)}</span>
        </div>
      </div>

      <section class="a-section">
        <h3>データ</h3>
        <div class="a-counter">
          <div class="nums">
            <div><span>現在</span><b>${fmt(d.since)}</b></div>
            <div><span>BIG</span><b>${fmt(d.big)}</b></div>
            <div><span>REG</span><b>${fmt(d.reg)}</b></div>
            <div><span>総回転</span><b>${fmt(d.total)}</b></div>
          </div>
          ${graphHtml(d)}
          <div class="rate">ボーナス合算 <span class="a-num">${rate(d.total, (d.big || 0) + (d.reg || 0))}</span>　BIG <span class="a-num">${rate(d.total, d.big)}</span>　REG <span class="a-num">${rate(d.total, d.reg)}</span></div>
        </div>
      </section>

      ${game && game.settings ? `
      <section class="a-section">
        <h3>設定</h3>
        <div class="a-seg num">${[1, 2, 3, 4, 5, 6].map((s) => `<button data-act="setting" data-v="${s}" class="${s === m.setting ? 'on' : ''}">${s}</button>`).join('')}</div>
        <div class="note">6 がいちばん出る。打っている人には見えない。変えるとすぐ次のゲームから効く</div>
      </section>` : ''}

      <section class="a-section">
        <h3>台の中</h3>
        <div class="a-state">
          <div><span>状態</span><b>${MODE[st.mode] || '—'}${left}</b></div>
          <div><span>ボーナスの持ち越し</span><b>${st.carried ? `<i class="a-dot"></i>${st.carried.toUpperCase()}` : 'なし'}</b></div>
          <div><span>告知ランプ</span><b>${st.lamp ? '<i class="a-dot"></i>点灯' : '消灯'}</b></div>
        </div>
      </section>

      <div class="a-actions">
        <button class="a-btn" data-act="teleport">${icon('pin')}この台へ移動</button>
        <button class="a-btn quiet" data-act="reset">${icon('reset')}${confirmReset ? 'もう一度押すと消す' : 'データを消す'}</button>
        <span class="a-spacer"></span>
        <button class="a-btn danger${confirmRemove ? ' confirm' : ''}" data-act="remove">${icon('trash')}${confirmRemove ? 'もう一度押すと撤去' : '撤去する'}</button>
      </div>`;
  }

  function placeHtml() {
    const g = A.games.find((x) => x.name === A.placeGame) || A.games[0];
    return `
      <div>
        <div class="a-title"><h2>台を置く</h2></div>
        <div class="a-meta"><span>ゲームと設定を選ぶと、画面を閉じて設置に入る。見ている場所に台と椅子の見本が出る</span></div>
      </div>
      <section class="a-section">
        <h3>ゲーム</h3>
        <div class="a-games">${A.games.map((x) => `<button class="a-game${g && x.name === g.name ? ' sel' : ''}" data-act="pickGame" data-v="${x.name}"><i class="radio"></i>${esc(x.label)}</button>`).join('')}</div>
      </section>
      ${g && g.settings ? `
      <section class="a-section">
        <h3>設定</h3>
        <div class="a-seg num">${[1, 2, 3, 4, 5, 6].map((s) => `<button data-act="placeSetting" data-v="${s}" class="${s === A.placeSetting ? 'on' : ''}">${s}</button>`).join('')}</div>
      </section>` : ''}
      <section class="a-section">
        <h3>設置中の操作</h3>
        <div class="a-keys">
          <span class="k"><span class="a-key">マウス</span></span><span>置く場所</span>
          <span class="k"><span class="a-key">ホイール</span><span class="a-key">Q</span><span class="a-key">E</span></span><span>向き（Shift で細かく）</span>
          <span class="k"><span class="a-key">G</span></span><span>近くの台の隣にそろえる（入・切）</span>
          <span class="k"><span class="a-key">Enter</span></span><span>置く（続けて何台でも）</span>
          <span class="k"><span class="a-key">Backspace</span></span><span>終わってこの画面に戻る</span>
        </div>
      </section>
      <div class="a-actions">
        <button class="a-btn primary" data-act="startPlace">設置を始める</button>
        <button class="a-btn quiet" data-act="cancelPlace">やめる</button>
      </div>`;
  }

  function render() {
    ensureRoot();
    const sorted = A.machines.slice().sort((a, b) => a.dist - b.dist);
    part('count').textContent = sorted.length;
    const list = part('list');
    const top = list.scrollTop; // 差し替えてもスクロール位置は残す
    list.innerHTML = sorted.map(rowHtml).join('') || '<div class="a-empty">まだ台がありません</div>';
    list.scrollTop = top;
    part('main').innerHTML = A.view === 'place' ? placeHtml() : detailHtml(selected());
    scaleWin();
  }

  function toast(text) {
    const el = $('aToast');
    if (!el || !text) return;
    el.textContent = text;
    el.classList.remove('hide');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.add('hide'), 2600);
  }

  function replaceRow(row) {
    if (!row) return;
    const i = A.machines.findIndex((m) => m.id === row.id);
    if (i >= 0) A.machines[i] = Object.assign({}, A.machines[i], row);
  }

  function armConfirm(key) {
    A.confirm = key;
    clearTimeout(confirmTimer);
    confirmTimer = setTimeout(() => { A.confirm = null; if (A.open) render(); }, 3000);
  }

  async function onClick(e) {
    const btn = e.target.closest('[data-act]');
    if (!btn) return;
    btn.blur();
    const act = btn.dataset.act;
    const m = selected();
    switch (act) {
      case 'close': return close();
      case 'refresh': {
        const res = await post('admin:refresh');
        if (res && res.machines) { load(res, false); toast('読み込み直しました'); }
        return;
      }
      case 'select': A.sel = +btn.dataset.id; A.view = 'detail'; A.confirm = null; return render();
      case 'place':
        A.view = 'place';
        A.placeGame = A.placeGame || (A.games[0] && A.games[0].name);
        A.placeSetting = A.defaultSetting;
        return render();
      case 'pickGame': A.placeGame = btn.dataset.v; return render();
      case 'placeSetting': A.placeSetting = +btn.dataset.v; return render();
      case 'cancelPlace': A.view = 'detail'; return render();
      case 'startPlace':
        A.open = false;
        root.classList.add('hidden');
        return post('admin:place', { game: A.placeGame, setting: A.placeSetting });
      case 'setting': {
        if (!m) return;
        const res = await post('admin:setting', { id: m.id, setting: +btn.dataset.v });
        if (res && res.ok) { replaceRow(res.row); render(); toast(`#${m.id} を設定${res.row.setting} にしました`); } else toast((res && res.reason) || '変えられませんでした');
        return;
      }
      case 'reset': {
        if (!m) return;
        if (A.confirm !== 'reset:' + m.id) { armConfirm('reset:' + m.id); return render(); }
        A.confirm = null;
        const res = await post('admin:reset', { id: m.id });
        if (res && res.ok) { replaceRow(res.row); render(); toast(`#${m.id} のデータを消しました`); } else toast((res && res.reason) || '消せませんでした');
        return;
      }
      case 'remove': {
        if (!m) return;
        if (A.confirm !== 'remove:' + m.id) { armConfirm('remove:' + m.id); return render(); }
        A.confirm = null;
        const res = await post('admin:remove', { id: m.id });
        if (res && res.ok) {
          A.machines = A.machines.filter((x) => x.id !== m.id);
          A.sel = null;
          render();
          toast(`#${m.id} を撤去しました`);
        } else { render(); toast((res && res.reason) || '撤去できませんでした'); }
        return;
      }
      case 'teleport':
        if (!m) return;
        A.open = false;
        root.classList.add('hidden');
        return post('admin:teleport', { id: m.id, x: m.x, y: m.y, z: m.z, h: m.h });
    }
  }

  function load(d, reset) {
    A.machines = d.machines || [];
    A.games = d.games || [];
    A.defaultSetting = d.defaultSetting || 1;
    if (d.bonusEnd) A.bonusEnd = d.bonusEnd;
    if (reset) { A.view = 'detail'; A.confirm = null; }
    if (d.select) A.sel = d.select;
    if (!A.machines.some((m) => m.id === A.sel)) {
      const near = A.machines.slice().sort((a, b) => a.dist - b.dist)[0];
      A.sel = near ? near.id : null;
    }
    render();
  }

  function open(d) {
    A.open = true;
    ensureRoot();
    part('list').scrollTop = 0; // 開き直した時は一覧の先頭から
    clearTimeout(toastTimer);
    $('aToast').classList.add('hide'); // 前に開いていた時のお知らせは消す
    load(d, true);
    root.classList.remove('hidden');
    if (d.message) toast(d.message);
  }

  function close() {
    A.open = false;
    if (root) root.classList.add('hidden');
    post('admin:close');
  }

  window.addEventListener('keydown', (e) => {
    if (!A.open) return;
    if (e.key === 'Escape') { e.preventDefault(); close(); }
  });

  window.addEventListener('message', (e) => {
    const d = e.data || {};
    if (d.action === 'admin') open(d);
    else if (d.action === 'adminClose' && A.open) { A.open = false; if (root) root.classList.add('hidden'); }
  });

  // =====================================================================
  // 打っている管理者の横の管理パネル（app.js が台の情報を渡す）
  // =====================================================================
  const panel = $('slotAdmin');
  let last = null;

  function renderPanel(info) {
    last = info;
    if (!info || !info.admin) { panel.classList.add('hidden'); return false; }
    const a = info.admin;
    panel.classList.remove('hidden');
    const force = a.force || 'off';
    panel.innerHTML = `
      <div class="h"><b>管理</b><span class="a-num">台 #${info.id}</span></div>
      <div class="grp">
        <span>確実に当たり</span>
        <div class="a-seg" style="grid-template-columns:repeat(3,1fr)">
          ${[['off', '切'], ['big', 'BIG'], ['reg', 'REG']].map(([v, l]) => `<button data-force="${v}" class="${force === v ? (v === 'off' ? 'on neutral' : 'on') : ''}">${l}</button>`).join('')}
        </div>
        <div class="note">${force === 'off' ? '入れると、次のレバーから毎回ボーナスが当たり、どこで押しても揃う' : `<span class="force-on">入っています</span>。通常時のレバーごとに ${force.toUpperCase()} が揃う。ボーナス中は普段どおり`}</div>
      </div>
      <div class="grp">
        <span>設定</span>
        <div class="a-seg num" style="grid-template-columns:repeat(6,1fr)">
          ${[1, 2, 3, 4, 5, 6].map((s) => `<button data-setting="${s}" class="${a.setting === s ? 'on' : ''}">${s}</button>`).join('')}
        </div>
      </div>
      <dl>
        <dt>状態</dt><dd>${MODE[info.mode] || '—'}</dd>
        <dt>持ち越し</dt><dd>${a.carried ? `<i class="a-dot"></i>${a.carried.toUpperCase()}` : 'なし'}</dd>
        <dt>告知ランプ</dt><dd>${info.lamp ? '<i class="a-dot"></i>点灯' : '消灯'}</dd>
      </dl>`;
    return true;
  }

  panel.addEventListener('click', async (e) => {
    const b = e.target.closest('button');
    if (!b) return;
    b.blur();
    let res = null;
    if (b.dataset.force) res = await post('slotAdmin:force', { mode: b.dataset.force === 'off' ? null : b.dataset.force });
    else if (b.dataset.setting) res = await post('slotAdmin:setting', { setting: +b.dataset.setting });
    if (res && res.ok && res.info && window.SlotApp) window.SlotApp.applyInfo(res.info);
  });

  window.SlotAdminPanel = { render: renderPanel };

  // =====================================================================
  // ブラウザで見るための見本（?preview&admin）
  // =====================================================================
  const Mock = {
    'admin:setting': (d) => { const m = A.machines.find((x) => x.id === d.id); return { ok: true, row: Object.assign({}, m, { setting: d.setting }) }; },
    'admin:reset': (d) => { const m = A.machines.find((x) => x.id === d.id); return { ok: true, row: Object.assign({}, m, { data: { total: 0, big: 0, reg: 0, since: 0, history: [] } }) }; },
    'admin:remove': () => ({ ok: true }),
    'admin:refresh': () => ({ machines: A.machines, games: A.games, defaultSetting: 1 }),
    'slotAdmin:force': (d) => { const i = Object.assign({}, last, { admin: Object.assign({}, last.admin, { force: d.mode }) }); return { ok: true, info: i }; },
    'slotAdmin:setting': (d) => { const i = Object.assign({}, last, { admin: Object.assign({}, last.admin, { setting: d.setting }) }); return { ok: true, info: i }; },
  };
  if (PREVIEW && Q.has('admin')) {
    window.addEventListener('load', () => open({
      games: [{ name: 'slot', label: 'パチスロ 夜祭', settings: true }],
      defaultSetting: 1,
      machines: [
        { id: 3, game: 'slot', label: 'パチスロ 夜祭', x: -1201.4, y: -1563.2, z: 4.6, h: 35, dist: 4.2, setting: 4, busy: true, seatName: '山田 太郎', lamp: true,
          data: { total: 1834, big: 6, reg: 4, since: 142, history: [{ t: 'big', g: 88 }, { t: 'reg', g: 301 }, { t: 'big', g: 46 }, { t: 'big', g: 412 }, { t: 'reg', g: 157 }, { t: 'big', g: 233 }, { t: 'reg', g: 19 }, { t: 'big', g: 264 }] },
          state: { mode: 'normal', carried: 'big', bonusPay: 0, lamp: true } },
        { id: 4, game: 'slot', label: 'パチスロ 夜祭', x: -1200.9, y: -1562.7, z: 4.6, h: 35, dist: 4.8, setting: 1, busy: false, lamp: false,
          data: { total: 922, big: 2, reg: 1, since: 377, history: [{ t: 'big', g: 301 }, { t: 'reg', g: 96 }, { t: 'big', g: 148 }] },
          state: { mode: 'normal', carried: null, bonusPay: 0, lamp: false } },
        { id: 5, game: 'slot', label: 'パチスロ 夜祭', x: -1200.4, y: -1562.2, z: 4.6, h: 35, dist: 5.3, setting: 6, busy: false, lamp: false,
          data: { total: 2410, big: 11, reg: 9, since: 23, history: [{ t: 'reg', g: 61 }, { t: 'big', g: 12 }] },
          state: { mode: 'big', carried: null, bonusPay: 105, lamp: false } },
        { id: 1, game: 'slot', label: 'パチスロ 夜祭', x: 154.2, y: -1040.8, z: 29.4, h: 160, dist: 1480, setting: 2, busy: false, lamp: false,
          data: { total: 0, big: 0, reg: 0, since: 0, history: [] }, state: { mode: 'normal', carried: null, bonusPay: 0, lamp: false } },
      ],
    }));
  }
})();
