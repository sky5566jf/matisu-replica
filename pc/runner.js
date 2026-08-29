/*
 * MatisuAuto PC 运行器 (Phase 0 验证)
 * 用纯 JS 的 Lua 5.1 VM (fengari) 验证：
 *   1) Lua 引擎可加载并执行脚本
 *   2) 统一 API 契约 (core.lua) 可被脚本调用
 *   3) 宿主(JS)函数可桥接为 Lua 全局 API（touch/device/ui/color...）
 *
 * 运行: NODE_PATH=<fengari所在node_modules> node runner.js
 */
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

// ---- 同步睡眠（Phase 0 演示用最简实现） ----
function sleepSync(ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) { /* busy wait */ }
}

// ---- 宿主(JS)真实实现，将桥接为 Lua 的 touch/device/ui/color API ----
function jsTap(L) {
  const x = lua.lua_tointeger(L, 1);
  const y = lua.lua_tointeger(L, 2);
  const delay = lua.lua_isnumber(L, 3) ? lua.lua_tointeger(L, 3) : 0;
  console.log(`[PC] touch.tap(${x}, ${y}${delay ? `, ${delay}ms` : ''})  -> 注入触控事件`);
  return 0;
}
function jsSwipe(L) {
  const x1 = lua.lua_tointeger(L, 1), y1 = lua.lua_tointeger(L, 2);
  const x2 = lua.lua_tointeger(L, 3), y2 = lua.lua_tointeger(L, 4);
  const dur = lua.lua_isnumber(L, 5) ? lua.lua_tointeger(L, 5) : 200;
  console.log(`[PC] touch.swipe(${x1},${y1})->(${x2},${y2}) ${dur}ms`);
  return 0;
}
function jsSleep(L) {
  const ms = lua.lua_tointeger(L, 1);
  sleepSync(ms);
  return 0;
}
function jsGetScreenSize(L) {
  lua.lua_createtable(L, 2, 0);
  lua.lua_pushinteger(L, 1080); lua.lua_rawseti(L, -2, 1);
  lua.lua_pushinteger(L, 2400); lua.lua_rawseti(L, -2, 2);
  return 1; // 返回 {1080, 2400}
}
function jsGetOSType(L) {
  lua.lua_pushstring(L, to_luastring('pc'));
  return 1;
}
function jsToast(L) {
  const msg = to_jsstring(lua.lua_tolstring(L, 1));
  console.log(`[PC][toast] ${msg}`);
  return 0;
}
function jsFindColor(L) {
  const c = to_jsstring(lua.lua_tolstring(L, 1));
  console.log(`[PC] color.findColor(${c}) -> 需在真机截图后实现，Phase 0 返回 nil`);
  lua.lua_pushnil(L);
  return 1;
}
function jsLog(L) {
  const n = lua.lua_gettop(L);
  const parts = [];
  for (let i = 1; i <= n; i++) {
    if (lua.lua_isstring(L, i)) parts.push(to_jsstring(lua.lua_tolstring(L, i)));
    else if (lua.lua_isnumber(L, i)) parts.push(String(lua.lua_tonumber(L, i)));
    else parts.push('(' + to_jsstring(lua.lua_typename(L, lua.lua_type(L, i))) + ')');
  }
  console.log(parts.join('\t'));
  return 0;
}

// ---- 1) 加载统一 API 契约 core.lua ----
const corePath = path.join(__dirname, '..', 'common', 'lua-api', 'core.lua');
const coreCode = fs.readFileSync(corePath, 'utf8');
if (lauxlib.luaL_dostring(L, to_luastring(coreCode)) !== 0) {
  console.error('core.lua 加载失败:', to_jsstring(lua.lua_tostring(L, -1)));
  process.exit(1);
}

// ---- 2) 把宿主实现桥接为 Lua 全局 API（覆盖默认桩） ----
function setField(tableName, fieldName, jsFunc) {
  lua.lua_getglobal(L, to_luastring(tableName));
  lua.lua_pushcfunction(L, jsFunc);
  lua.lua_setfield(L, -2, to_luastring(fieldName));
  lua.lua_pop(L, 1);
}
setField('touch', 'tap', jsTap);
setField('touch', 'swipe', jsSwipe);
setField('device', 'sleep', jsSleep);
setField('device', 'getScreenSize', jsGetScreenSize);
setField('device', 'getOSType', jsGetOSType);
setField('ui', 'toast', jsToast);
setField('color', 'findColor', jsFindColor);
setField('console', 'log', jsLog);
// 全局简写 log 也覆盖
lua.lua_pushcfunction(L, jsLog);
lua.lua_setglobal(L, to_luastring('log'));

// ---- 3) 运行用户脚本 demo.lua ----
const demoPath = path.join(__dirname, 'demo.lua');
const demoCode = fs.readFileSync(demoPath, 'utf8');
console.log('\n===== 运行 demo.lua =====');
if (lauxlib.luaL_dostring(L, to_luastring(demoCode)) !== 0) {
  console.error('demo.lua 运行错误:', to_jsstring(lua.lua_tostring(L, -1)));
  process.exit(1);
}
console.log('===== demo.lua 结束 =====');
lua.lua_close(L);
