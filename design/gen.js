// リール図柄とパネルの絵を SVG で作る。node gen.js → design/svg/*.svg
// 図柄は 160x120（横長）。パネルは台の大きさに合わせた比率で作る
const fs = require('fs');
const path = require('path');
const out = path.join(__dirname, 'svg');
fs.mkdirSync(out, { recursive: true });

const MINCHO = "'Yu Mincho','YuMincho','Hiragino Mincho ProN',serif";
const BLACK = "'Arial Black','Arial',sans-serif";

function svg(w, h, body, defs = '') {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">` +
    `<defs>${defs}</defs>${body}</svg>`;
}

// ---- リール図柄 ----
const symbols = {};

// 赤7: 少し斜めにした太い 7。金の縁取り
symbols.seven = svg(160, 120, `
  <g transform="translate(80 60) skewX(-10) translate(-80 -60)">
    <path d="M40 14 H124 V32 L90 108 H62 L96 34 H58 V44 H40 Z" fill="#3a0606" transform="translate(3 4)"/>
    <path d="M40 14 H124 V32 L90 108 H62 L96 34 H58 V44 H40 Z" fill="url(#red7)" stroke="#f5c542" stroke-width="5" stroke-linejoin="round"/>
    <path d="M46 19 H118 V26 H46 Z" fill="#ffffff" opacity=".35"/>
  </g>`,
  `<linearGradient id="red7" x1="0" y1="0" x2="0" y2="1">
     <stop offset="0" stop-color="#ff5a4a"/><stop offset=".55" stop-color="#d4141c"/><stop offset="1" stop-color="#8e0a10"/>
   </linearGradient>`);

// 提灯: 赤い提灯に「祭」
symbols.lantern = svg(160, 120, `
  <rect x="62" y="6" width="36" height="12" rx="3" fill="#1d1d1d"/>
  <rect x="62" y="102" width="36" height="12" rx="3" fill="#1d1d1d"/>
  <ellipse cx="80" cy="60" rx="40" ry="44" fill="url(#lan)" stroke="#5e0b0b" stroke-width="3"/>
  ${[30, 42, 54, 66, 78, 90].map(y => {
    const dx = 40 * Math.sqrt(Math.max(0, 1 - ((y - 60) / 44) ** 2));
    return `<path d="M${80 - dx} ${y} Q80 ${y + 5} ${80 + dx} ${y}" fill="none" stroke="#7a1010" stroke-width="1.6" opacity=".7"/>`;
  }).join('')}
  <text x="80" y="76" text-anchor="middle" font-family="${MINCHO}" font-weight="700" font-size="44" fill="#151515">祭</text>
  <ellipse cx="66" cy="40" rx="9" ry="14" fill="#fff" opacity=".22"/>`,
  `<radialGradient id="lan" cx=".45" cy=".4" r=".7">
     <stop offset="0" stop-color="#ff7b54"/><stop offset=".6" stop-color="#e2261c"/><stop offset="1" stop-color="#9b0f0f"/>
   </radialGradient>`);

// BAR: 黒い板に金文字
symbols.bar = svg(160, 120, `
  <rect x="16" y="30" width="128" height="60" rx="10" fill="#111" stroke="#f5c542" stroke-width="5"/>
  <rect x="24" y="37" width="112" height="46" rx="6" fill="none" stroke="#f5c542" stroke-width="1.5" opacity=".6"/>
  <text x="80" y="77" text-anchor="middle" font-family="${BLACK}" font-size="38" fill="#ffe08a" letter-spacing="2">BAR</text>`);

// ベル: 金のベル
symbols.bell = svg(160, 120, `
  <path d="M80 12 C58 12 50 32 50 52 C50 72 44 82 32 92 H128 C116 82 110 72 110 52 C110 32 102 12 80 12 Z"
        fill="url(#bell)" stroke="#7a4a00" stroke-width="4" stroke-linejoin="round"/>
  <rect x="28" y="90" width="104" height="10" rx="5" fill="#d69a12" stroke="#7a4a00" stroke-width="3"/>
  <circle cx="80" cy="108" r="8" fill="#d69a12" stroke="#7a4a00" stroke-width="3"/>
  <circle cx="80" cy="10" r="5" fill="#d69a12" stroke="#7a4a00" stroke-width="3"/>
  <path d="M66 26 C58 34 58 52 58 62" fill="none" stroke="#fff6c8" stroke-width="6" stroke-linecap="round" opacity=".8"/>`,
  `<linearGradient id="bell" x1="0" y1="0" x2="1" y2="0">
     <stop offset="0" stop-color="#f7c832"/><stop offset=".35" stop-color="#ffe680"/><stop offset="1" stop-color="#d08a00"/>
   </linearGradient>`);

// スイカ: 縞模様の丸いスイカ
symbols.suika = svg(160, 120, `
  <ellipse cx="80" cy="62" rx="50" ry="46" fill="#2f9e3a" stroke="#0d4a17" stroke-width="4"/>
  ${[-30, -15, 0, 15, 30].map(x =>
    `<path d="M${80 + x} 18 q${-6} 11 0 22 t0 22 t0 22 t0 22" fill="none" stroke="#0f4f1b" stroke-width="6" stroke-linecap="round"
      transform="scale(1 1)" opacity=".95"/>`).join('')}
  <ellipse cx="62" cy="40" rx="12" ry="8" fill="#fff" opacity=".25"/>
  <path d="M80 16 q4 -8 12 -10" fill="none" stroke="#5a3b12" stroke-width="4" stroke-linecap="round"/>`);

// チェリー: 2つの実と葉
symbols.cherry = svg(160, 120, `
  <path d="M84 18 C76 40 62 56 54 78" fill="none" stroke="#3d6b12" stroke-width="5" stroke-linecap="round"/>
  <path d="M84 18 C92 40 100 58 106 80" fill="none" stroke="#3d6b12" stroke-width="5" stroke-linecap="round"/>
  <path d="M84 18 C96 6 118 8 126 18 C112 26 96 26 84 18 Z" fill="#4caf1d" stroke="#245c0c" stroke-width="3"/>
  <circle cx="52" cy="88" r="22" fill="url(#chr)" stroke="#5c0010" stroke-width="3.5"/>
  <circle cx="106" cy="90" r="22" fill="url(#chr)" stroke="#5c0010" stroke-width="3.5"/>
  <circle cx="44" cy="80" r="6" fill="#fff" opacity=".6"/>
  <circle cx="98" cy="82" r="6" fill="#fff" opacity=".6"/>`,
  `<radialGradient id="chr" cx=".4" cy=".35" r=".7">
     <stop offset="0" stop-color="#ff5d73"/><stop offset=".6" stop-color="#d0102e"/><stop offset="1" stop-color="#7d0418"/>
   </radialGradient>`);

// リプレイ: 青い板に REPLAY
symbols.replay = svg(160, 120, `
  <rect x="12" y="34" width="136" height="52" rx="26" fill="#1565c0" stroke="#0b2f63" stroke-width="4"/>
  <rect x="18" y="39" width="124" height="20" rx="10" fill="#fff" opacity=".18"/>
  <text x="80" y="70" text-anchor="middle" font-family="${BLACK}" font-size="22" fill="#fff" letter-spacing="1">REPLAY</text>`);

for (const [k, v] of Object.entries(symbols)) fs.writeFileSync(path.join(out, `sym_${k}.svg`), v);

// ---- 上部パネル（夜祭のタイトル）512x320 ----
const stars = Array.from({ length: 40 }, (_, i) => {
  const x = (i * 97) % 512, y = (i * 53) % 150, r = (i % 3) * 0.6 + 0.6;
  return `<circle cx="${x}" cy="${y}" r="${r}" fill="#fff" opacity="${0.3 + (i % 4) * 0.15}"/>`;
}).join('');
function firework(cx, cy, r, color, n = 18) {
  let s = '';
  for (let i = 0; i < n; i++) {
    const a = (i / n) * Math.PI * 2;
    const x1 = cx + Math.cos(a) * r * 0.25, y1 = cy + Math.sin(a) * r * 0.25;
    const x2 = cx + Math.cos(a) * r, y2 = cy + Math.sin(a) * r;
    s += `<line x1="${x1.toFixed(1)}" y1="${y1.toFixed(1)}" x2="${x2.toFixed(1)}" y2="${y2.toFixed(1)}" stroke="${color}" stroke-width="2.4" stroke-linecap="round"/>`;
    s += `<circle cx="${x2.toFixed(1)}" cy="${y2.toFixed(1)}" r="2.6" fill="${color}"/>`;
  }
  return `<g opacity=".95">${s}</g>`;
}
function hangLantern(x, y, s) {
  return `<g transform="translate(${x} ${y}) scale(${s})">
    <line x1="0" y1="-30" x2="0" y2="-20" stroke="#222" stroke-width="2"/>
    <rect x="-9" y="-22" width="18" height="6" rx="2" fill="#222"/>
    <ellipse cx="0" cy="0" rx="18" ry="20" fill="#ff5a2a"/>
    <ellipse cx="0" cy="0" rx="18" ry="20" fill="url(#glow)" opacity=".8"/>
    <rect x="-9" y="16" width="18" height="6" rx="2" fill="#222"/>
  </g>`;
}
const upper = svg(512, 320, `
  <rect width="512" height="320" fill="url(#sky)"/>
  ${stars}
  ${firework(110, 80, 58, '#ffd36b')}
  ${firework(400, 70, 66, '#ff7aa8', 22)}
  ${firework(300, 40, 30, '#8fe3ff', 14)}
  <path d="M0 250 Q256 200 512 250 V320 H0 Z" fill="#160d24"/>
  <path d="M0 232 Q128 222 256 232 T512 232" fill="none" stroke="#3b2a12" stroke-width="2"/>
  ${[40, 110, 180, 256, 332, 402, 472].map((x, i) => hangLantern(x, 246 + (i % 2) * 6, 0.9)).join('')}
  <text x="256" y="186" text-anchor="middle" font-family="${MINCHO}" font-weight="700" font-size="128"
        fill="#2a0505" transform="translate(4 5)">夜祭</text>
  <text x="256" y="186" text-anchor="middle" font-family="${MINCHO}" font-weight="700" font-size="128"
        fill="url(#gold)" stroke="#5a2a00" stroke-width="3">夜祭</text>
  <text x="256" y="226" text-anchor="middle" font-family="${BLACK}" font-size="20" fill="#ffe7a3" letter-spacing="10">YOMATSURI</text>`,
  `<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
     <stop offset="0" stop-color="#0b0f2e"/><stop offset=".7" stop-color="#2a1550"/><stop offset="1" stop-color="#4a1840"/>
   </linearGradient>
   <linearGradient id="gold" x1="0" y1="0" x2="0" y2="1">
     <stop offset="0" stop-color="#fff3b0"/><stop offset=".45" stop-color="#ffc83a"/><stop offset="1" stop-color="#c46a00"/>
   </linearGradient>
   <radialGradient id="glow" cx=".5" cy=".45" r=".6">
     <stop offset="0" stop-color="#fff2a8"/><stop offset="1" stop-color="#ff5a2a" stop-opacity="0"/>
   </radialGradient>`);
fs.writeFileSync(path.join(out, 'panel_upper.svg'), upper);

// ---- 下部パネル（腰部）512x256 ----
const lower = svg(512, 256, `
  <rect width="512" height="256" fill="url(#lsky)"/>
  ${firework(70, 50, 38, '#ffd36b', 16)}
  ${firework(450, 44, 34, '#9ef0c0', 16)}
  <path d="M0 180 Q130 150 256 176 T512 168 V256 H0 Z" fill="#120a1e"/>
  ${[60, 150, 256, 362, 452].map((x, i) => hangLantern(x, 150 + (i % 2) * 8, 1.1)).join('')}
  <text x="256" y="112" text-anchor="middle" font-family="${MINCHO}" font-weight="700" font-size="42"
        fill="url(#lgold)" stroke="#5a2a00" stroke-width="2">提灯が灯れば大当たり</text>`,
  `<linearGradient id="lsky" x1="0" y1="0" x2="0" y2="1">
     <stop offset="0" stop-color="#14123a"/><stop offset="1" stop-color="#3d1240"/>
   </linearGradient>
   <linearGradient id="lgold" x1="0" y1="0" x2="0" y2="1">
     <stop offset="0" stop-color="#fff3b0"/><stop offset="1" stop-color="#e09a1a"/>
   </linearGradient>
   <radialGradient id="glow" cx=".5" cy=".45" r=".6">
     <stop offset="0" stop-color="#fff2a8"/><stop offset="1" stop-color="#ff5a2a" stop-opacity="0"/>
   </radialGradient>`);
fs.writeFileSync(path.join(out, 'panel_lower.svg'), lower);

// ---- 告知ランプ（提灯ランプ、点灯と消灯）128x160 ----
function lampSvg(on) {
  return svg(128, 160, `
    <rect x="44" y="4" width="40" height="16" rx="4" fill="#1d1d1d"/>
    <rect x="44" y="140" width="40" height="16" rx="4" fill="#1d1d1d"/>
    <ellipse cx="64" cy="80" rx="54" ry="62" fill="${on ? 'url(#lon)' : '#4a1414'}" stroke="#2a0606" stroke-width="3"/>
    ${[40, 56, 72, 88, 104, 120].map(y => {
      const dx = 54 * Math.sqrt(Math.max(0, 1 - ((y - 80) / 62) ** 2));
      return `<path d="M${64 - dx} ${y} Q64 ${y + 6} ${64 + dx} ${y}" fill="none" stroke="${on ? '#b3271a' : '#2c0a0a'}" stroke-width="2"/>`;
    }).join('')}
    <text x="64" y="102" text-anchor="middle" font-family="${MINCHO}" font-weight="700" font-size="60"
          fill="${on ? '#1a0500' : '#250808'}">祭</text>`,
    `<radialGradient id="lon" cx=".5" cy=".45" r=".65">
       <stop offset="0" stop-color="#fff6c2"/><stop offset=".45" stop-color="#ffb347"/><stop offset="1" stop-color="#e2321c"/>
     </radialGradient>`);
}
fs.writeFileSync(path.join(out, 'lamp_on.svg'), lampSvg(true));
fs.writeFileSync(path.join(out, 'lamp_off.svg'), lampSvg(false));

console.log('ok', fs.readdirSync(out).length);
