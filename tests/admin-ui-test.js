// 管理画面（/arcadeadmin）でボタンを押した時に、窓が開き直さない（作り直されない・フェードし直さない・一覧のスクロールが戻らない）ことを確かめる
// html/index.html?preview&admin をヘッドレス Chromium で開いて実際にクリックする（追加の部品なし、Node 22 以降）
// node tests/admin-ui-test.js [スクリーンショットの出力フォルダ]
const { spawn } = require('child_process');
const fs = require('fs'), path = require('path');
const { pathToFileURL } = require('url');

const outDir = process.argv[2];
const page = pathToFileURL(path.resolve(__dirname, '../html/index.html')).href + '?preview&admin';
const SHELL = path.join(process.env.LOCALAPPDATA, 'ms-playwright/chromium_headless_shell-1148/chrome-win/headless_shell.exe');
const port = 9335;
const proc = spawn(SHELL, ['--headless', '--disable-gpu', `--remote-debugging-port=${port}`, '--window-size=1920,1080',
  '--allow-file-access-from-files', '--hide-scrollbars', 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let pass = 0, fail = 0;
function check(name, got, want) {
  if (JSON.stringify(got) === JSON.stringify(want)) { pass++; console.log('OK  ', name); }
  else { fail++; console.log('NG  ', name, '期待:', JSON.stringify(want), '実際:', JSON.stringify(got)); }
}

(async () => {
  let ws;
  for (let i = 0; i < 50; i++) {
    try { const list = await (await fetch(`http://127.0.0.1:${port}/json`)).json(); const pg = list.find((t) => t.type === 'page'); if (pg) { ws = new WebSocket(pg.webSocketDebuggerUrl); break; } } catch (e) {}
    await sleep(200);
  }
  await new Promise((r) => ws.addEventListener('open', r));
  let id = 0; const pending = new Map();
  ws.addEventListener('message', (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } });
  const send = (method, params = {}) => new Promise((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
  const evalJs = async (expression) => {
    const r = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (r.result.exceptionDetails) throw new Error(r.result.exceptionDetails.exception.description);
    return r.result.result.value;
  };

  await send('Page.enable'); await send('Runtime.enable');
  await send('Emulation.setDeviceMetricsOverride', { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false });
  await send('Page.navigate', { url: page });
  await sleep(1200);

  // 一覧がスクロールするよう、台を 24 台にして開き直す（ゲームから開いた時と同じ action: 'admin'）
  await evalJs(`(() => {
    const machines = [];
    for (let i = 1; i <= 24; i++) machines.push({ id: i, game: 'slot', label: 'パチスロ 夜祭', x: i, y: 0, z: 0, h: 0, dist: i * 3, setting: (i % 6) + 1, busy: false, lamp: i % 5 === 0,
      data: { total: 100 * i, big: i % 4, reg: i % 3, since: 10 * i, history: [{ t: 'big', g: 80 + i }, { t: 'reg', g: 200 - i }] },
      state: { mode: 'normal', carried: null, bonusPay: 0, lamp: false } });
    window.postMessage({ action: 'admin', machines, games: [{ name: 'slot', label: 'パチスロ 夜祭', settings: true }], defaultSetting: 1 }, '*');
    return true;
  })()`);
  await sleep(600);

  // 開いた時のアニメーションが終わった後の状態を覚える
  await evalJs(`(() => { window.__win = document.querySelector('#admin .a-win'); const l = document.querySelector('#admin .a-list'); l.scrollTop = 300; return true })()`);
  const scroll0 = await evalJs(`document.querySelector('#admin .a-list').scrollTop`);
  check('一覧がスクロールできる（下準備）', scroll0 > 0, true);

  // ボタンを押してすぐ（50ms 後）の様子を見る
  async function clickAndSee(label, selector) {
    await evalJs(`document.querySelector(${JSON.stringify(selector)}).click(); true`);
    await sleep(50);
    const s = await evalJs(`(() => {
      const w = document.querySelector('#admin .a-win');
      return {
        same: w === window.__win,
        running: w.getAnimations().filter((a) => a.playState === 'running').length,
        opacity: +getComputedStyle(w).opacity,
        scroll: document.querySelector('#admin .a-list').scrollTop,
      };
    })()`);
    check(`${label}: 窓を作り直さない`, s.same, true);
    check(`${label}: フェードし直さない`, s.running === 0 && s.opacity === 1, true);
    check(`${label}: 一覧のスクロールが戻らない`, s.scroll, scroll0);
    await sleep(200);
  }

  await clickAndSee('設定を変える', '#admin [data-act=setting][data-v="5"]');
  check('設定が変わった', await evalJs(`document.querySelector('#admin [data-act=setting].on').dataset.v`), '5');
  await clickAndSee('別の台を選ぶ', '#admin .a-list [data-act=select][data-id="12"]');
  check('選んだ台に変わった', await evalJs(`document.querySelector('#admin .a-list .a-row.sel').dataset.id`), '12');
  await clickAndSee('データを消す（1回目）', '#admin [data-act=reset]');
  await clickAndSee('データを消す（2回目）', '#admin [data-act=reset]');
  await clickAndSee('台を置く', '#admin [data-act=place]');
  await clickAndSee('やめる', '#admin [data-act=cancelPlace]');
  await clickAndSee('読み込み直す', '#admin [data-act=refresh]');
  await sleep(100);
  check('読み込み直した後もトーストが出る', await evalJs(`!document.getElementById('aToast').classList.contains('hide')`), true);

  // 閉じて開き直した時は、アニメーションが出る
  await evalJs(`window.postMessage({ action: 'adminClose' }, '*'); true`);
  await sleep(100);
  await evalJs(`window.postMessage({ action: 'admin', machines: [{ id: 1, game: 'slot', label: 'x', x: 0, y: 0, z: 0, h: 0, dist: 1, setting: 1, data: { total: 0, big: 0, reg: 0, since: 0, history: [] }, state: { mode: 'normal' } }], games: [], defaultSetting: 1 }, '*'); true`);
  await sleep(50);
  check('開き直した時はアニメーションが出る', await evalJs(`document.querySelector('#admin .a-win').getAnimations().length > 0`), true);
  check('開き直した時は前のお知らせを消す', await evalJs(`document.getElementById('aToast').classList.contains('hide')`), true);
  check('開き直した時は一覧の先頭から', await evalJs(`document.querySelector('#admin .a-list').scrollTop`), 0);
  await sleep(500);

  if (outDir) {
    fs.mkdirSync(outDir, { recursive: true });
    const r = await send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(path.join(outDir, 'admin.png'), Buffer.from(r.result.data, 'base64'));
    console.log('shot', path.join(outDir, 'admin.png'));
  }

  console.log(`\n${pass} OK / ${fail} NG`);
  ws.close(); proc.kill();
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); proc.kill(); process.exit(1); });
