// Lua の構文と、未定義のグローバル参照を調べる。node check.js
const fs = require('fs'), path = require('path');
module.paths.push(process.env.NODE_MODULES || '');
const luaparse = require('luaparse');
const dir = path.join(__dirname, '..');
const files = ['config.lua', 'shared/slot_engine.lua', 'server/main.lua', 'server/slot.lua', 'server/start.lua', 'client/main.lua', 'client/slot.lua',
  'shared/pachi_board.lua', 'server/pachi_physics.lua', 'server/pachi_engine.lua', 'server/pachi.lua', 'client/pachi.lua', 'fxmanifest.lua'];
const known = new Set(('Config SlotEngine PachiEngine PachiBoard PachiPhysics Arcade ArcadeClient lib cache exports json MySQL GlobalState LocalPlayer source vec2 vec3 vec4 vector3 ' +
  'print pairs ipairs type tostring tonumber math table string os next select error pcall setmetatable ' +
  'CreateThread Wait GetGameTimer TriggerClientEvent AddEventHandler RegisterNetEvent RegisterCommand RegisterNUICallback ' +
  'GetPlayerPed GetEntityCoords GetPlayerName GetCurrentResourceName IsPlayerAceAllowed ' +
  'CreateObjectNoOffset SetEntityHeading FreezeEntityPosition DoesEntityExist DeleteEntity GetOffsetFromEntityInWorldCoords ' +
  'DrawLightWithRange SetNuiFocus SendNUIMessage ClearPedTasks SetEntityCoords SetEntityCoordsNoOffset TaskStartScenarioAtPosition ' +
  'IsEntityDead IsPedRagdoll IsPedInAnyVehicle SetEntityAlpha SetEntityCollision GetEntityHeading DisableControlAction ' +
  'IsDisabledControlPressed IsDisabledControlJustPressed SetModelAsNoLongerNeeded ' +
  'fx_version game lua54 name description author version ui_page files data_file shared_scripts client_scripts server_scripts dependencies').split(/\s+/));
let bad = 0;
for (const f of files) {
  let src = fs.readFileSync(path.join(dir, f), 'utf8');
  if (src.charCodeAt(0) === 0xfeff) { console.log(f, 'BOM あり'); bad++; }
  if (src.includes('\r')) { console.log(f, 'CR あり'); bad++; }
  src = src.replace(/`[A-Za-z0-9_]+`/g, '0'); // FiveM のハッシュ文字列
  let ast;
  try { ast = luaparse.parse(src, { scope: true, luaVersion: '5.3' }); } catch (e) { console.log(f, '構文エラー', e.message); bad++; continue; }
  const globals = new Set();
  (function walk(n) {
    if (!n || typeof n !== 'object') return;
    if (Array.isArray(n)) return n.forEach(walk);
    if (n.type === 'Identifier' && n.isLocal === false && !known.has(n.name)) globals.add(n.name);
    for (const k in n) if (k !== 'type') walk(n[k]);
  })(ast.body);
  if (globals.size) bad++;
  console.log(f, 'OK', globals.size ? '未知のグローバル: ' + [...globals].join(', ') : '');
}
process.exit(bad ? 1 : 0);
