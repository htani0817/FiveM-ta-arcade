// fengari で Lua を動かす。node lua-run.js <テスト.lua> [引数...]
// リソースのファイルは SOURCES[ファイル名] で読める。ARGS に引数が入る
const fs = require('fs'), path = require('path');
module.paths.push(process.env.NODE_MODULES || '');
const { lua, lauxlib, lualib, to_luastring } = require('fengari');
const dir = path.join(__dirname, '..');
const [test, ...args] = process.argv.slice(2);
const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);
lua.lua_newtable(L);
for (const f of ['config.lua', 'shared/slot_engine.lua', 'server/main.lua', 'server/slot.lua', 'server/start.lua', 'client/main.lua', 'client/slot.lua',
  'server/pachi_engine.lua', 'server/pachi.lua', 'client/pachi.lua']) {
  const p = path.join(dir, f);
  if (!fs.existsSync(p)) continue;
  lua.lua_pushstring(L, to_luastring(fs.readFileSync(p, 'utf8')));
  lua.lua_setfield(L, -2, to_luastring(f));
}
lua.lua_setglobal(L, to_luastring('SOURCES'));
lua.lua_newtable(L);
args.forEach((a, i) => { lua.lua_pushstring(L, to_luastring(a)); lua.lua_rawseti(L, -2, i + 1); });
lua.lua_setglobal(L, to_luastring('ARGS'));
if (lauxlib.luaL_loadstring(L, to_luastring(fs.readFileSync(test, 'utf8'))) !== 0 || lua.lua_pcall(L, 0, 0, 0) !== 0) {
  console.error('エラー:', lua.lua_tojsstring(L, -1));
  process.exit(1);
}
