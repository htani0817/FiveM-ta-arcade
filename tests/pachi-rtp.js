// パチンコの払い出し率を出す。入賞の割合を物理計算で測り（pachi-rates.js）、その割合で計算する（pachi-rtp.lua）
// node pachi-rtp.js [強さごとに打つ玉数（既定 40000）] [check]
const path = require('path');
const { execFileSync } = require('child_process');
const n = process.argv[2] || '40000';
const run = (args) => execFileSync(process.execPath, args, { cwd: __dirname, encoding: 'utf8', env: process.env, maxBuffer: 1 << 26 });
const rates = run([path.join(__dirname, 'pachi-rates.js'), n, 'rtp']).trim().split(/\s+/);
process.stdout.write(run([path.join(__dirname, 'lua-run.js'), path.join(__dirname, 'pachi-rtp.lua'), ...rates, ...(process.argv[3] === 'check' ? ['check'] : [])]));
