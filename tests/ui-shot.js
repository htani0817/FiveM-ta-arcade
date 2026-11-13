// 画面をヘッドレス Chromium で開き、キーを押しながら実時間でスクリーンショットを撮る（追加の部品なし）
// node ui-shot.js <URL> <出力フォルダ> "<手順>"   手順の例: "wait:800,key: ,wait:600,shot:spin,key:ArrowLeft,wait:300,shot:a"
const { spawn } = require('child_process');
const fs = require('fs'), path = require('path');
const [url, outDir, steps] = process.argv.slice(2);
const SHELL = path.join(process.env.LOCALAPPDATA, 'ms-playwright/chromium_headless_shell-1148/chrome-win/headless_shell.exe');
const port = 9333;
const proc = spawn(SHELL, ['--headless', '--disable-gpu', `--remote-debugging-port=${port}`, '--window-size=1920,1080',
  '--allow-file-access-from-files', '--hide-scrollbars', '--autoplay-policy=no-user-gesture-required', 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
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
  await send('Page.enable'); await send('Runtime.enable');
  await send('Emulation.setDeviceMetricsOverride', { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false });
  await send('Page.navigate', { url });
  await sleep(1200);
  fs.mkdirSync(outDir, { recursive: true });
  for (const st of steps.split(',')) {
    const [k, ...rest] = st.split(':'); const v = rest.join(':');
    if (k === 'wait') await sleep(+v);
    else if (k === 'key') {
      const key = v === '' ? ' ' : v;
      const codes = { ' ': ['Space', 32], ArrowLeft: ['ArrowLeft', 37], ArrowDown: ['ArrowDown', 40], ArrowRight: ['ArrowRight', 39], Escape: ['Escape', 27] };
      const [code, kc] = codes[key] || ['Key' + key.toUpperCase(), key.toUpperCase().charCodeAt(0)];
      await send('Input.dispatchKeyEvent', { type: 'keyDown', key, code, windowsVirtualKeyCode: kc, text: key.length === 1 ? key : undefined });
      await send('Input.dispatchKeyEvent', { type: 'keyUp', key, code, windowsVirtualKeyCode: kc });
    } else if (k === 'eval') {
      const r = await send('Runtime.evaluate', { expression: v, returnByValue: true }); console.log('eval', JSON.stringify(r.result.result.value));
    } else if (k === 'shot') {
      const r = await send('Page.captureScreenshot', { format: 'png' });
      fs.writeFileSync(path.join(outDir, v + '.png'), Buffer.from(r.result.data, 'base64')); console.log('shot', v);
    }
  }
  ws.close(); proc.kill();
})().catch((e) => { console.error(e); proc.kill(); process.exit(1); });
