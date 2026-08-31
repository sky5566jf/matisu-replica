/*
 * MatisuAuto PC 运行器（对齐「懒人精灵 高级版 2.0.1」真实 API）
 * 用纯 JS 的 Lua 5.1 VM (fengari) 加载统一 API 契约 core.lua，
 * 再把宿主(JS)真实实现桥接为 Lua 全局 API，覆盖 core.lua 的占位桩。
 *
 * 真实 API 表面（来自官方文档，已纠正旧 v1.3 偏差）：
 *   - 触控/图色/设备/应用/系统/交互 一律是【全局函数】（非 color.* / device.* 表）
 *   - 颜色格式 BBGGRR，多色 "|" 分隔，偏色 "-" 分隔
 *   - 节点为【选择器链式全局工厂】+ 选择器对象 sel:findOne/findAll/findOnce
 *   - 节点方法 node:*() 通过冒号调用（node:text()/node:click()/node:bounds()...）
 *   - 模块表：nodeLib.* / imeLib.* / ui.*（动态UI）/ cipher.* / network.* / json.*
 *
 * 运行: node runner.js [脚本.lua]   （MATISU_TARGET=android 走真机）
 */
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFileSync } = require('child_process');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');
const bridge = require('./device_bridge');

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

const CURL = 'C:/Windows/System32/curl.exe';

// 同步睡眠（Atomics.wait 阻塞线程，不占 CPU）
function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, Math.max(0, ms | 0));
}

// Lua 值读取
function num(L, i, d) { return lua.lua_isnumber(L, i) ? lua.lua_tonumber(L, i) : (d == null ? 0 : d); }
function str(L, i) { return lua.lua_isstring(L, i) ? to_jsstring(lua.lua_tolstring(L, i)) : ''; }

// ---------------- fengari 表 <-> JS 值 ----------------
function luaValToJs(L, idx) {
  if (lua.lua_istable(L, idx)) {
    const obj = {};
    let isArr = true, maxn = 0;
    lua.lua_pushnil(L);
    while (lua.lua_next(L, idx)) {
      let k;
      if (lua.lua_isnumber(L, idx + 1)) { k = lua.lua_tonumber(L, idx + 1); if (!Number.isInteger(k)) isArr = false; else maxn = Math.max(maxn, k); }
      else { k = str(L, idx + 1); isArr = false; }
      const v = luaValToJs(L, idx + 2);
      obj[k] = v;
      lua.lua_pop(L, 1);
    }
    if (isArr && maxn > 0) { const arr = []; for (let i = 1; i <= maxn; i++) arr[i - 1] = obj[i]; return arr; }
    return obj;
  }
  if (lua.lua_isnumber(L, idx)) return lua.lua_tonumber(L, idx);
  if (lua.lua_isstring(L, idx)) return str(L, idx);
  if (lua.lua_isboolean(L, idx)) return lua.lua_toboolean(L, idx) !== 0;
  return null;
}
function pushJsToLua(L, val) {
  if (val === null || val === undefined) lua.lua_pushnil(L);
  else if (Array.isArray(val)) {
    lua.lua_createtable(L, val.length, 0);
    val.forEach((v, i) => { pushJsToLua(L, v); lua.lua_rawseti(L, -2, i + 1); });
  } else if (typeof val === 'object') {
    const ks = Object.keys(val);
    lua.lua_createtable(L, 0, ks.length);
    for (const k of ks) { lua.lua_pushstring(L, to_luastring(String(k))); pushJsToLua(L, val[k]); lua.lua_settable(L, -3); }
  } else if (typeof val === 'string') lua.lua_pushstring(L, to_luastring(val));
  // 整数走 pushinteger：否则 Lua 5.3+ 会把 1 打印成 1.0，与原版行为不一致
  else if (typeof val === 'number') {
    if (Number.isInteger(val) && Math.abs(val) <= Number.MAX_SAFE_INTEGER) lua.lua_pushinteger(L, val);
    else lua.lua_pushnumber(L, val);
  }
  else if (typeof val === 'boolean') lua.lua_pushboolean(L, val ? 1 : 0);
  else lua.lua_pushnil(L);
}

// 全局注册助手
function regGlobal(name, fn) { lua.lua_pushcfunction(L, fn); lua.lua_setglobal(L, to_luastring(name)); }
function setField(tableName, fieldName, jsFunc) {
  lua.lua_getglobal(L, to_luastring(tableName));
  if (lua.lua_isnil(L, -1)) { lua.lua_pop(L, 1); lua.lua_createtable(L, 0, 0); lua.lua_setglobal(L, to_luastring(tableName)); lua.lua_getglobal(L, to_luastring(tableName)); }
  lua.lua_pushcfunction(L, jsFunc);
  lua.lua_setfield(L, -2, to_luastring(fieldName));
  lua.lua_pop(L, 1);
}

// ============================================================
// 一、触控（全局函数）
// ============================================================
function jsTap(L) { bridge.tap(num(L, 1), num(L, 2)); return 0; }
function jsLongTap(L) { bridge.longTap(num(L, 1), num(L, 2)); return 0; }
function jsSwipe(L) { bridge.swipe(num(L, 1), num(L, 2), num(L, 3), num(L, 4), num(L, 5, 300)); return 0; }
function jsTouchDown(L) { bridge.touchDown(num(L, 1, 0), num(L, 2), num(L, 3)); return 0; }
function jsTouchMove(L) { bridge.touchMove(num(L, 1, 0), num(L, 2), num(L, 3)); return 0; }
function jsTouchMoveEx(L) { bridge.touchMoveEx(num(L, 1, 0), num(L, 2), num(L, 3), num(L, 4, 300)); return 0; }
// 官方两种写法都合法：touchUp(id) / touchUp(id,x,y)。省略坐标时交给桥接层用该指最后落点。
function jsTouchUp(L) {
  const hasXY = lua.lua_isnumber(L, 2) && lua.lua_isnumber(L, 3);
  bridge.touchUp(num(L, 1, 0), hasXY ? lua.lua_tonumber(L, 2) : null, hasXY ? lua.lua_tonumber(L, 3) : null);
  return 0;
}
function jsInputText(L) { bridge.inputText(str(L, 1)); return 0; }
function jsKeyPress(L) { const k = lua.lua_isstring(L, 1) ? str(L, 1) : num(L, 1); bridge.keyPress(k); return 0; }
function jsKeyDown(L) { const k = lua.lua_isstring(L, 1) ? str(L, 1) : num(L, 1); bridge.keyDown(k); return 0; }
function jsKeyUp(L) { const k = lua.lua_isstring(L, 1) ? str(L, 1) : num(L, 1); bridge.keyUp(k); return 0; }
function jsSetOnTouchListener(L) { console.log('[touch] setOnTouchListener PC 宿主未实现（需设备侧常驻服务）'); lua.lua_pushboolean(L, 0); return 1; }

// ============================================================
// 二、图色与找图（全局函数，颜色 BBGGRR）
// ============================================================
function jsFindColor(L) {
  const x1 = num(L, 1, 0), y1 = num(L, 2, 0), x2 = num(L, 3, 0), y2 = num(L, 4, 0);
  const color = str(L, 5), dir = num(L, 6, 0), sim = num(L, 7, 0.9);
  const r = bridge.findColor(x1, y1, x2, y2, color, dir, sim);
  lua.lua_pushinteger(L, r[0]); lua.lua_pushinteger(L, r[1]); lua.lua_pushinteger(L, r[2]); return 3;
}
function jsFindColorT(L) {
  const tb = lua.lua_istable(L, 1) ? luaValToJs(L, 1) : [];
  const r = bridge.findColor(tb[0] || 0, tb[1] || 0, tb[2] || 0, tb[3] || 0, tb[4] || '', tb[5] || 0, tb[6] == null ? 0.9 : tb[6]);
  lua.lua_pushinteger(L, r[0]); lua.lua_pushinteger(L, r[1]); lua.lua_pushinteger(L, r[2]); return 3;
}
function jsFindMultiColor(L) {
  const x1 = num(L, 1, 0), y1 = num(L, 2, 0), x2 = num(L, 3, 0), y2 = num(L, 4, 0);
  const first = str(L, 5), offset = str(L, 6), dir = num(L, 7, 0), sim = num(L, 8, 0.9);
  const r = bridge.findMultiColor(x1, y1, x2, y2, first, offset, dir, sim);
  lua.lua_pushinteger(L, r[0]); lua.lua_pushinteger(L, r[1]); return 2;
}
function jsFindMultiColorT(L) {
  const tb = lua.lua_istable(L, 1) ? luaValToJs(L, 1) : [];
  const r = bridge.findMultiColor(tb[0] || 0, tb[1] || 0, tb[2] || 0, tb[3] || 0, tb[4] || '', tb[5] || '', tb[6] || 0, tb[7] == null ? 0.9 : tb[7]);
  lua.lua_pushinteger(L, r[0]); lua.lua_pushinteger(L, r[1]); return 2;
}
function jsFindMultiColorAll(L) {
  const x1 = num(L, 1, 0), y1 = num(L, 2, 0), x2 = num(L, 3, 0), y2 = num(L, 4, 0);
  const first = str(L, 5), offset = str(L, 6), dir = num(L, 7, 0), sim = num(L, 8, 0.9);
  const list = bridge.findMultiColorAll(x1, y1, x2, y2, first, offset, dir, sim) || [];
  lua.lua_createtable(L, list.length, 0);
  list.forEach((p, i) => { pushJsToLua(L, { x: p.x, y: p.y }); lua.lua_rawseti(L, -2, i + 1); });
  return 1;
}
function jsFindMultiColorAllT(L) {
  const tb = lua.lua_istable(L, 1) ? luaValToJs(L, 1) : [];
  const list = bridge.findMultiColorAll(tb[0] || 0, tb[1] || 0, tb[2] || 0, tb[3] || 0, tb[4] || '', tb[5] || '', tb[6] || 0, tb[7] == null ? 0.9 : tb[7]) || [];
  lua.lua_createtable(L, list.length, 0);
  list.forEach((p, i) => { pushJsToLua(L, { x: p.x, y: p.y }); lua.lua_rawseti(L, -2, i + 1); });
  return 1;
}
function jsCmpColor(L) {
  const r = bridge.cmpColor(num(L, 1), num(L, 2), str(L, 3), num(L, 4, 0.9));
  lua.lua_pushinteger(L, r ? 1 : 0); return 1;
}
function jsCmpColorEx(L) {
  const r = bridge.cmpColorEx(str(L, 1), num(L, 2, 0.9));
  lua.lua_pushinteger(L, r ? 1 : 0); return 1;
}
function jsCmpColorExT(L) {
  const tb = lua.lua_istable(L, 1) ? luaValToJs(L, 1) : [];
  const r = bridge.cmpColorEx(tb[0] || '', tb[1] == null ? 0.9 : tb[1]);
  lua.lua_pushinteger(L, r ? 1 : 0); return 1;
}
function jsGetColorNum(L) {
  const r = bridge.getColorNum(num(L, 1, 0), num(L, 2, 0), num(L, 3, 0), num(L, 4, 0), str(L, 5), num(L, 6, 0.9));
  lua.lua_pushinteger(L, r || 0); return 1;
}
function parseColorInt(L, i) {
  if (lua.lua_isnumber(L, i)) return lua.lua_tonumber(L, i) >>> 0;
  if (lua.lua_isstring(L, i)) { const s = str(L, i).replace(/^0x/i, ''); const v = parseInt(s, 16); return isNaN(v) ? 0 : (v >>> 0); }
  return 0;
}
function jsColorDiff(L) {
  const r = bridge.colorDiff(parseColorInt(L, 1), parseColorInt(L, 2));
  lua.lua_pushinteger(L, r || 0); return 1;
}
function jsColorToRGB(L) {
  const [r, g, b] = bridge.colorToRGB(parseColorInt(L, 1));
  lua.lua_pushinteger(L, r); lua.lua_pushinteger(L, g); lua.lua_pushinteger(L, b); return 3;
}
function jsGetPixelColor(L) {
  const type = lua.lua_isnumber(L, 3) ? lua.lua_tointeger(L, 3) : 0;
  const c = bridge.getPixelColor(num(L, 1), num(L, 2), type);
  if (type === 1) lua.lua_pushinteger(L, typeof c === 'number' ? c : 0);
  else lua.lua_pushstring(L, to_luastring(typeof c === 'string' ? c : '000000'));
  return 1;
}
function jsGetScreenPixel(L) {
  const [w, h, arr] = bridge.getScreenPixel(num(L, 1, 0), num(L, 2, 0), num(L, 3, 0), num(L, 4, 0));
  lua.lua_pushinteger(L, w); lua.lua_pushinteger(L, h); pushJsToLua(L, arr || []); return 3;
}
function jsIsDisplayDead(L) {
  const r = bridge.isDisplayDead(num(L, 1, 0), num(L, 2, 0), num(L, 3, 0), num(L, 4, 0), num(L, 5, 5));
  lua.lua_pushboolean(L, r ? 1 : 0); return 1;
}
function jsKeepCapture(L) { bridge.keepCapture(); return 0; }
function jsReleaseCapture(L) { bridge.releaseCapture(); return 0; }
function jsSetScreenScale(L) {
  const type = num(L, 1), w = num(L, 2), h = num(L, 3);
  const scale = lua.lua_isnumber(L, 4) ? num(L, 4, 1) : 1;
  bridge.setScreenScale(type, w, h, scale); return 0;
}
function jsSnapShot(L) {
  const p = str(L, 1);
  const x1 = num(L, 2, 0), y1 = num(L, 3, 0), x2 = num(L, 4, 0), y2 = num(L, 5, 0);
  const r = bridge.snapShot(p, x1, y1, x2, y2);
  if (r) lua.lua_pushstring(L, to_luastring(r)); else lua.lua_pushnil(L);
  return 1;
}
function jsOcrText(L) {
  const x1 = num(L, 1, 0), y1 = num(L, 2, 0), x2 = num(L, 3, 0), y2 = num(L, 4, 0);
  const lang = lua.lua_isstring(L, 5) ? str(L, 5) : 'chi_sim+eng';
  const r = bridge.ocrText(lang, x1, y1, x2, y2);
  lua.lua_pushstring(L, to_luastring(r || '')); return 1;
}
// 找图系（PC 宿主暂未实现模板匹配，返回未命中形状；接口已对齐）
function jsImageStub2(L) { lua.lua_pushinteger(L, -1); lua.lua_pushinteger(L, -1); return 2; }
function jsImageStub3(L) { lua.lua_pushinteger(L, -1); lua.lua_pushinteger(L, -1); lua.lua_pushnil(L); return 3; }
function jsImageArr(L) { console.log('[image] 找图系 PC 宿主待实现（opencv 模板匹配）'); lua.lua_createtable(L, 0, 0); return 1; }
function jsFindCircle(L) { console.log('[image] findCircle PC 宿主待实现'); lua.lua_createtable(L, 0, 0); return 1; }

// ---- 找图（模板匹配，桥接层 JS 实现已落地）----
function pushRetXY(L, r) {
  if (!r || r[0] < 0) { lua.lua_pushinteger(L, -1); lua.lua_pushinteger(L, -1); lua.lua_pushnil(L); }
  else { lua.lua_pushinteger(L, r[0]); lua.lua_pushinteger(L, r[1]); lua.lua_pushinteger(L, r[2]); }
  return 3;
}
function jsFindPic(L) {
  const r = bridge.findPic(num(L, 1, 0), num(L, 2, 0), num(L, 3, 0), num(L, 4, 0), str(L, 5), str(L, 6), num(L, 7, 0), num(L, 8, 0.9));
  return pushRetXY(L, r);
}
function jsFindPicEx(L) {
  const r = bridge.findPicEx(num(L, 1, 0), num(L, 2, 0), num(L, 3, 0), num(L, 4, 0), str(L, 5), num(L, 6, 0.9));
  return pushRetXY(L, r);
}
function jsFindImage(L) {
  const r = bridge.findImage(num(L, 1, 0), num(L, 2, 0), num(L, 3, 0), num(L, 4, 0), str(L, 5), num(L, 6, 0.9));
  return pushRetXY(L, r);
}
function jsFindPicAllPoint(L) {
  const list = bridge.findPicAllPoint(num(L, 1, 0), num(L, 2, 0), num(L, 3, 0), num(L, 4, 0), str(L, 5), num(L, 6, 0.9));
  pushJsToLua(L, list || []); return 1;
}

// ============================================================
// 三、节点选择器（41 全局工厂 + 选择器对象）
// ============================================================
const SELECTOR_SPECS = [
  { fn: 'id', k: 'id', m: 'eq' }, { fn: 'idContains', k: 'id', m: 'contains' },
  { fn: 'idStartsWith', k: 'id', m: 'startsWith' }, { fn: 'idEndsWith', k: 'id', m: 'endsWith' }, { fn: 'idMatches', k: 'id', m: 'matches' },
  { fn: 'text', k: 'text', m: 'eq' }, { fn: 'textContains', k: 'text', m: 'contains' },
  { fn: 'textStartsWith', k: 'text', m: 'startsWith' }, { fn: 'textEndsWith', k: 'text', m: 'endsWith' }, { fn: 'textMatches', k: 'text', m: 'matches' },
  { fn: 'desc', k: 'desc', m: 'eq' }, { fn: 'descContains', k: 'desc', m: 'contains' },
  { fn: 'descStartsWith', k: 'desc', m: 'startsWith' }, { fn: 'descEndsWith', k: 'desc', m: 'endsWith' }, { fn: 'descMatches', k: 'desc', m: 'matches' },
  { fn: 'className', k: 'className', m: 'eq' }, { fn: 'classNameContains', k: 'className', m: 'contains' },
  { fn: 'classNameStartsWith', k: 'className', m: 'startsWith' }, { fn: 'classNameEndsWith', k: 'className', m: 'endsWith' }, { fn: 'classNameMatches', k: 'className', m: 'matches' },
  { fn: 'packageName', k: 'packageName', m: 'eq' }, { fn: 'packageNameContains', k: 'packageName', m: 'contains' },
  { fn: 'packageNameStartsWith', k: 'packageName', m: 'startsWith' }, { fn: 'packageNameEndsWith', k: 'packageName', m: 'endsWith' }, { fn: 'packageNameMatches', k: 'packageName', m: 'matches' },
  { fn: 'bounds', k: 'bounds', m: null }, { fn: 'boundsInside', k: 'boundsInside', m: null },
  { fn: 'drawingOrder', k: 'drawingOrder', m: null }, { fn: 'depth', k: 'depth', m: null }, { fn: 'index', k: 'index', m: null },
  { fn: 'visibleToUser', k: 'visibleToUser', m: null }, { fn: 'selected', k: 'selected', m: null },
  { fn: 'clickable', k: 'clickable', m: null }, { fn: 'longClickable', k: 'longClickable', m: null },
  { fn: 'enabled', k: 'enabled', m: null }, { fn: 'password', k: 'password', m: null },
  { fn: 'scrollable', k: 'scrollable', m: null }, { fn: 'checked', k: 'checked', m: null },
  { fn: 'checkable', k: 'checkable', m: null }, { fn: 'focusable', k: 'focusable', m: null }, { fn: 'focused', k: 'focused', m: null },
];
const BOOL_KEYS = new Set(['visibleToUser', 'selected', 'clickable', 'longClickable', 'enabled', 'password', 'scrollable', 'checked', 'checkable', 'focusable', 'focused']);
const INT_KEYS = new Set(['drawingOrder', 'depth', 'index']);

const selectors = new Map();
let sidSeq = 1;
const nodeStore = new Map();
let nidSeq = 1;

function predVal(L, k, i) {
  if (k === 'bounds' || k === 'boundsInside') {
    if (!lua.lua_istable(L, i)) return null;
    const a = luaValToJs(L, i);
    if (Array.isArray(a) && a.length >= 4) return [a[0] | 0, a[1] | 0, a[2] | 0, a[3] | 0];
    return null;
  }
  if (INT_KEYS.has(k)) return num(L, i, 0);
  if (BOOL_KEYS.has(k)) return lua.lua_toboolean(L, i) !== 0;
  return str(L, i);
}

function getSid(L) {
  lua.lua_getfield(L, 1, to_luastring('_sid'));
  const sid = lua.lua_tointeger(L, -1);
  lua.lua_pop(L, 1);
  return sid;
}
function selFromLua(L) {
  const sid = getSid(L);
  return selectors.get(sid);
}

function setSelectorMethods(L) {
  for (const spec of SELECTOR_SPECS) {
    lua.lua_pushcfunction(L, (L2) => jsSelMethod(L2, spec));
    lua.lua_setfield(L, -2, to_luastring(spec.fn));
  }
  lua.lua_pushcfunction(L, jsFindOne); lua.lua_setfield(L, -2, to_luastring('findOne'));
  lua.lua_pushcfunction(L, jsFindAll); lua.lua_setfield(L, -2, to_luastring('findAll'));
  lua.lua_pushcfunction(L, jsFindOnce); lua.lua_setfield(L, -2, to_luastring('findOnce'));
}
function makeSelector(L, preds) {
  const sid = sidSeq++;
  selectors.set(sid, { preds });
  lua.lua_createtable(L, 0, 4);
  lua.lua_pushstring(L, to_luastring('_sid'));
  lua.lua_pushinteger(L, sid);
  lua.lua_settable(L, -3);
  lua.lua_createtable(L, 0, 50);
  setSelectorMethods(L);
  // Lua 仅通过元表的 __index 查找缺失键（方法），必须把 __index 指向方法表自身
  lua.lua_pushstring(L, to_luastring('__index'));   // [T, M, '__index']
  lua.lua_pushvalue(L, -2);                          // [T, M, '__index', M]
  lua.lua_settable(L, -3);                           // M.__index = M  -> [T, M]
  lua.lua_setmetatable(L, -2);                       // T 的元表 = M    -> [T]
}
function jsSelStarter(L, spec) {
  const v = predVal(L, spec.k, 1);
  makeSelector(L, [{ k: spec.k, m: spec.m, v }]);
  return 1;
}
function jsSelMethod(L, spec) {
  const s = selFromLua(L);
  if (s) {
    const v = predVal(L, spec.k, 2);
    if (spec.k === 'bounds' || spec.k === 'boundsInside') {
      if (!v) { console.warn('[selector] ' + spec.fn + ' 需传入 {l,t,r,b}'); lua.lua_pushvalue(L, 1); return 1; }
    }
    s.preds.push({ k: spec.k, m: spec.m, v });
  }
  lua.lua_pushvalue(L, 1); // 返回 self 以支持链式
  return 1;
}
function doFindOne(preds, timeout) {
  const t = timeout > 0 ? timeout : 30000; // 默认最多等 30s，避免永久挂起
  const deadline = Date.now() + t;
  while (true) {
    const r = bridge.nodeQuery(preds, 'one');
    if (r) return r;
    if (timeout > 0 && Date.now() >= deadline) return null;
    sleepSync(200);
  }
}
function jsFindOne(L) {
  const s = selFromLua(L); if (!s) { lua.lua_pushnil(L); return 1; }
  const timeout = lua.lua_isnumber(L, 2) ? num(L, 2, 0) : 0;
  const r = doFindOne(s.preds, timeout);
  if (r) { pushNode(L, r); return 1; }
  lua.lua_pushnil(L); return 1;
}
function jsFindAll(L) {
  const s = selFromLua(L); if (!s) { lua.lua_createtable(L, 0, 0); return 1; }
  const list = bridge.nodeQuery(s.preds, 'all') || [];
  pushNodeList(L, list); return 1;
}
function jsFindOnce(L) {
  const s = selFromLua(L); if (!s) { lua.lua_pushnil(L); return 1; }
  const index = lua.lua_isnumber(L, 2) ? num(L, 2, 0) : 0;
  const r = bridge.nodeQuery(s.preds, 'once', index);
  if (r && r.node) { pushNode(L, r.node); return 1; }
  lua.lua_pushnil(L); return 1;
}

// ---------------- 节点对象桥接 ----------------
function nodeNid(L) {
  lua.lua_getfield(L, 1, to_luastring('_nid'));
  const nid = lua.lua_tointeger(L, -1);
  lua.lua_pop(L, 1);
  return nodeStore.get(nid);
}
function pushNode(L, n) {
  if (!n) { lua.lua_pushnil(L); return; }
  const nid = nidSeq++;
  nodeStore.set(nid, n);
  lua.lua_createtable(L, 0, 50);
  lua.lua_pushstring(L, to_luastring('_nid'));
  lua.lua_pushinteger(L, nid);
  lua.lua_settable(L, -3);
  setNodeMethods(L);
}
function pushNodeList(L, list) {
  const arr = (list && list.list) ? list.list : (Array.isArray(list) ? list : []);
  lua.lua_createtable(L, arr.length, 0);
  arr.forEach((n, i) => { pushNode(L, n); lua.lua_rawseti(L, -2, i + 1); });
}
function scrollNode(L, dir) {
  const n = nodeNid(L); if (!n) return;
  const cx = n.cx, cy = n.cy;
  const halfH = Math.max(10, ((n.bottom - n.top) >> 1) - 10);
  const halfW = Math.max(10, ((n.right - n.left) >> 1) - 10);
  if (dir === 0) bridge.swipe(cx, cy + halfH, cx, cy - halfH, 200);
  else if (dir === 1) bridge.swipe(cx, cy - halfH, cx, cy + halfH, 200);
  else if (dir === 2) bridge.swipe(cx + halfW, cy, cx - halfW, cy, 200);
  else bridge.swipe(cx - halfW, cy, cx + halfW, cy, 200);
}
function nmText(L) { const n = nodeNid(L); lua.lua_pushstring(L, to_luastring((n && n.text) || '')); return 1; }
function nmId(L) { const n = nodeNid(L); lua.lua_pushstring(L, to_luastring((n && n.id) || '')); return 1; }
function nmDesc(L) { const n = nodeNid(L); lua.lua_pushstring(L, to_luastring((n && n.desc) || '')); return 1; }
function nmClassName(L) { const n = nodeNid(L); lua.lua_pushstring(L, to_luastring((n && n.className) || '')); return 1; }
function nmPackageName(L) { const n = nodeNid(L); lua.lua_pushstring(L, to_luastring((n && n.packageName) || '')); return 1; }
function nmBounds(L) { const n = nodeNid(L); lua.lua_pushinteger(L, n ? n.left : 0); lua.lua_pushinteger(L, n ? n.top : 0); lua.lua_pushinteger(L, n ? n.right : 0); lua.lua_pushinteger(L, n ? n.bottom : 0); return 4; }
function nmBoundsInParent(L) { const n = nodeNid(L); lua.lua_pushinteger(L, n ? n.left : 0); lua.lua_pushinteger(L, n ? n.top : 0); lua.lua_pushinteger(L, n ? n.right : 0); lua.lua_pushinteger(L, n ? n.bottom : 0); return 4; }
function nmChildCount(L) { const n = nodeNid(L); lua.lua_pushinteger(L, (n && n.childCount) || 0); return 1; }
function nmChilds(L) {
  const n = nodeNid(L); const cs = (n && n.childs) || [];
  if (!cs.length) { lua.lua_createtable(L, 0, 0); return 1; }
  const r = bridge.nodeQuery([], 'index', undefined, cs);
  pushNodeList(L, r); return 1;
}
function nmParent(L) {
  const n = nodeNid(L); const p = n ? n.parent : null;
  if (p == null || p < 0) { lua.lua_pushnil(L); return 1; }
  const r = bridge.nodeQuery([], 'index', undefined, [p]);
  if (r && r.node) { pushNode(L, r.node); return 1; }
  lua.lua_pushnil(L); return 1;
}
function nmDrawingOrder(L) { const n = nodeNid(L); lua.lua_pushinteger(L, (n && n.drawingOrder) || 0); return 1; }
function nmDepth(L) { const n = nodeNid(L); lua.lua_pushinteger(L, (n && n.depth) || 0); return 1; }
function nmToJson(L) { const n = nodeNid(L); lua.lua_pushstring(L, to_luastring(JSON.stringify(n || {}))); return 1; }
function nmClick(L) { const n = nodeNid(L); if (n) bridge.tap(n.cx, n.cy); lua.lua_pushboolean(L, n ? 1 : 0); return 1; }
function nmLongClick(L) { const n = nodeNid(L); if (n) bridge.longTap(n.cx, n.cy); lua.lua_pushboolean(L, n ? 1 : 0); return 1; }
function nmSetText(L) { const n = nodeNid(L); if (n) { bridge.tap(n.cx, n.cy); bridge.inputText(str(L, 2)); } lua.lua_pushboolean(L, n ? 1 : 0); return 1; }
function nmFocus(L) { const n = nodeNid(L); if (n) bridge.tap(n.cx, n.cy); lua.lua_pushboolean(L, n ? 1 : 0); return 1; }
function nmClearFocus(L) { lua.lua_pushboolean(L, 1); return 1; }
function nmSelect(L) { const n = nodeNid(L); if (n) bridge.tap(n.cx, n.cy); lua.lua_pushboolean(L, n ? 1 : 0); return 1; }
function nmContextClick(L) { const n = nodeNid(L); if (n) bridge.tap(n.cx, n.cy); lua.lua_pushboolean(L, n ? 1 : 0); return 1; }
function nmSetSelection(L) { const n = nodeNid(L); if (n) bridge.tap(n.cx, n.cy); lua.lua_pushboolean(L, n ? 1 : 0); return 1; }
function nmSetProgress(L) { lua.lua_pushboolean(L, 1); return 1; }
function nmCollapse(L) { lua.lua_pushboolean(L, 1); return 1; }
function nmExpand(L) { lua.lua_pushboolean(L, 1); return 1; }
function nmCopy(L) { console.log('[node] copy (PC 宿主无障碍未实现，best-effort)'); lua.lua_pushboolean(L, 1); return 1; }
function nmPaste(L) { console.log('[node] paste (PC 宿主无障碍未实现，best-effort)'); lua.lua_pushboolean(L, 1); return 1; }
function nmCut(L) { console.log('[node] cut (PC 宿主无障碍未实现，best-effort)'); lua.lua_pushboolean(L, 1); return 1; }
function nmScrollTo(L) { scrollNode(L, 1); lua.lua_pushboolean(L, 1); return 1; }
function nmScrollUp(L) { scrollNode(L, 0); lua.lua_pushboolean(L, 1); return 1; }
function nmScrollDown(L) { scrollNode(L, 1); lua.lua_pushboolean(L, 1); return 1; }
function nmScrollLeft(L) { scrollNode(L, 2); lua.lua_pushboolean(L, 1); return 1; }
function nmScrollRight(L) { scrollNode(L, 3); lua.lua_pushboolean(L, 1); return 1; }
function nmScrollForward(L) { scrollNode(L, 1); lua.lua_pushboolean(L, 1); return 1; }
function nmScrollBackward(L) { scrollNode(L, 0); lua.lua_pushboolean(L, 1); return 1; }

function setNodeMethods(L) {
  const methods = [
    ['text', nmText], ['id', nmId], ['desc', nmDesc], ['className', nmClassName], ['packageName', nmPackageName],
    ['bounds', nmBounds], ['boundsInParent', nmBoundsInParent], ['childCount', nmChildCount], ['childs', nmChilds],
    ['parent', nmParent], ['drawingOrder', nmDrawingOrder], ['depth', nmDepth], ['toJson', nmToJson],
    ['setText', nmSetText], ['scrollTo', nmScrollTo], ['scrollUp', nmScrollUp], ['scrollDown', nmScrollDown],
    ['scrollLeft', nmScrollLeft], ['scrollRight', nmScrollRight], ['scrollForward', nmScrollForward],
    ['scrollBackward', nmScrollBackward], ['click', nmClick], ['longClick', nmLongClick], ['focus', nmFocus],
    ['clearFocus', nmClearFocus], ['copy', nmCopy], ['paste', nmPaste], ['cut', nmCut], ['select', nmSelect],
    ['setSelection', nmSetSelection], ['setProgress', nmSetProgress], ['collapse', nmCollapse],
    ['expand', nmExpand], ['contextClick', nmContextClick],
  ];
  for (const [name, fn] of methods) { lua.lua_pushcfunction(L, fn); lua.lua_setfield(L, -2, to_luastring(name)); }
}

// ============================================================
// 四、设备信息（全局函数）
// ============================================================
function jsGetDisplaySize(L) { const [w, h] = bridge.getDisplaySize(); lua.lua_pushinteger(L, w); lua.lua_pushinteger(L, h); return 2; }
function jsGetDisplayInfo(L) { lua.lua_pushstring(L, to_luastring(bridge.getDisplayInfo() || '{}')); return 1; }
function jsGetCpuArch(L) { lua.lua_pushinteger(L, bridge.getCpuArch()); return 1; }
function jsInt0(name) { return function (L) { lua.lua_pushinteger(L, bridge[name]() || 0); return 1; }; }
function jsStr0(name) { return function (L) { lua.lua_pushstring(L, to_luastring(bridge[name]() || '')); return 1; }; }

// ============================================================
// 五、应用管理（全局函数）
// ============================================================
function jsRunApp(L) { bridge.runApp(str(L, 1), lua.lua_isstring(L, 2) ? str(L, 2) : undefined, lua.lua_toboolean(L, 3) ? true : false); return 0; }
function jsStopApp(L) { bridge.stopApp(str(L, 1)); return 0; }
function jsGetInstalledApk(L) { pushJsToLua(L, bridge.getInstalledApk() || []); return 1; }
function jsFrontAppName(L) { lua.lua_pushstring(L, to_luastring(bridge.frontAppName() || '')); return 1; }
function jsAppIsFront(L) { lua.lua_pushboolean(L, bridge.appIsFront(str(L, 1)) ? 1 : 0); return 1; }
function jsAppIsRunning(L) { lua.lua_pushboolean(L, bridge.appIsRunning(str(L, 1)) ? 1 : 0); return 1; }
function jsGetCurrentActivity(L) { lua.lua_pushstring(L, to_luastring(bridge.getCurrentActivity() || '')); return 1; }
function jsReadPasteboard(L) { lua.lua_pushstring(L, to_luastring(bridge.readPasteboard() || '')); return 1; }
function jsWritePasteboard(L) { bridge.writePasteboard(str(L, 1)); return 0; }
function jsPhoneCall(L) { bridge.phoneCall(str(L, 1)); return 0; }
function jsRunIntent(L) { const t = lua.lua_istable(L, 1) ? luaValToJs(L, 1) : {}; bridge.runIntent(t.action, t.uri); return 0; }
function jsInstallApk(L) { lua.lua_pushboolean(L, bridge.installApk(str(L, 1)) ? 1 : 0); return 1; }

// ============================================================
// 六、系统控制（全局函数）
// ============================================================
function jsSetControlBarPosNew(L) { bridge.setControlBarPosNew(num(L, 1), num(L, 2)); return 0; }
function jsShowControlBar(L) { bridge.showControlBar(lua.lua_toboolean(L, 1)); return 0; }
function jsVibrate(L) { bridge.vibrate(num(L, 1, 100)); return 0; }
function jsRnd(L) { const a = num(L, 1), b = num(L, 2); lua.lua_pushinteger(L, Math.floor(Math.random() * (b - a + 1)) + a); return 1; }
function jsExec(L) { const r = bridge.exec(str(L, 1), lua.lua_isboolean(L, 2) ? lua.lua_toboolean(L, 2) : true); lua.lua_pushstring(L, to_luastring(r || '')); return 1; }
function jsSleep(L) { sleepSync(num(L, 1, 0)); return 0; }
function jsLockScreen(L) { bridge.lockScreen(); return 0; }
function jsUnLockScreen(L) { bridge.unLockScreen(); return 0; }
function jsSetBTEnable(L) { bridge.setBTEnable(lua.lua_toboolean(L, 1)); return 0; }
function jsSetWifiEnable(L) { bridge.setWifiEnable(lua.lua_toboolean(L, 1)); return 0; }
function jsSetAirplaneMode(L) { bridge.setAirplaneMode(lua.lua_toboolean(L, 1)); return 0; }
function jsGetRunEnvType(L) { lua.lua_pushinteger(L, bridge.getRunEnvType()); return 1; }
function jsExitScript(L) { console.log('[system] exitScript'); callStopCb(); process.exit(0); }
// 脚本停止回调（懒人 setStopCallBack 语义：脚本被停止/退出前回调一次）
let stopCbRef = null;
function callStopCb() {
  if (stopCbRef == null) return;
  const ref = stopCbRef; stopCbRef = null;
  lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, ref);
  if (lua.lua_pcall(L, 0, 0, 0) !== 0) console.error('[stopCallBack] 回调执行错误:', to_jsstring(lua.lua_tostring(L, -1)));
  lauxlib.luaL_unref(L, lua.LUA_REGISTRYINDEX, ref);
}
function jsSetStopCallBack(L) {
  if (lua.lua_isfunction(L, 1)) { lua.lua_pushvalue(L, 1); stopCbRef = lauxlib.luaL_ref(L, lua.LUA_REGISTRYINDEX); }
  return 0;
}
// 重启脚本：置标志位并经 Lua error 中断当前执行，外层循环捕获后重跑
let restartFlag = false;
function jsRestartScript(L) { restartFlag = true; return lauxlib.luaL_error(L, to_luastring('__MATISU_RESTART__')); }

// ============================================================
// 七、交互（全局函数）
// ============================================================
function jsToast(L) { bridge.toast(str(L, 1), lua.lua_isnumber(L, 2) ? num(L, 2) : 0, lua.lua_isnumber(L, 3) ? num(L, 3) : 0, lua.lua_isnumber(L, 4) ? num(L, 4) : 12); return 0; }
function jsHideToast(L) { bridge.hideToast(); return 0; }
function jsShowUI(L) { console.log('[ui] showUI (PC 宿主无 UI 引擎，返回空)'); lua.lua_pushnil(L); return 1; }
function jsShowUIEx(L) { console.log('[ui] showUIEx (PC 宿主无 UI 引擎，返回空)'); lua.lua_pushnil(L); return 1; }
function jsCreateHUD(L) { console.log('[ui] createHUD (PC 宿主未实现)'); lua.lua_pushnil(L); return 1; }
function jsShowHUD(L) { console.log('[ui] showHUD (PC 宿主未实现)'); return 0; }
function jsHideHUD(L) { return 0; }

// ============================================================
// 加载 core.lua -> 覆盖为真实实现
// ============================================================
const corePath = path.join(__dirname, '..', 'common', 'lua-api', 'core.lua');
const coreCode = fs.readFileSync(corePath, 'utf8');
if (lauxlib.luaL_dostring(L, to_luastring(coreCode)) !== 0) {
  console.error('core.lua 加载失败:', to_jsstring(lua.lua_tostring(L, -1)));
  process.exit(1);
}

// ---- 触控 ----
['tap', 'longTap', 'swipe', 'touchDown', 'touchMove', 'touchMoveEx', 'touchUp', 'inputText', 'keyPress', 'keyDown', 'keyUp'].forEach((n) => {
  const fns = { tap: jsTap, longTap: jsLongTap, swipe: jsSwipe, touchDown: jsTouchDown, touchMove: jsTouchMove, touchMoveEx: jsTouchMoveEx, touchUp: jsTouchUp, inputText: jsInputText, keyPress: jsKeyPress, keyDown: jsKeyDown, keyUp: jsKeyUp };
  regGlobal(n, fns[n]);
});
regGlobal('setOnTouchListener', jsSetOnTouchListener);

// ---- 图色/找图 ----
regGlobal('findColor', jsFindColor);
regGlobal('findColorT', jsFindColorT);
regGlobal('findMultiColor', jsFindMultiColor);
regGlobal('findMultiColorT', jsFindMultiColorT);
regGlobal('findMultiColorAll', jsFindMultiColorAll);
regGlobal('findMultiColorAllT', jsFindMultiColorAllT);
regGlobal('cmpColor', jsCmpColor);
regGlobal('cmpColorEx', jsCmpColorEx);
regGlobal('cmpColorExT', jsCmpColorExT);
regGlobal('getColorNum', jsGetColorNum);
regGlobal('colorDiff', jsColorDiff);
regGlobal('colorToRGB', jsColorToRGB);
regGlobal('getPixelColor', jsGetPixelColor);
regGlobal('getScreenPixel', jsGetScreenPixel);
regGlobal('isDisplayDead', jsIsDisplayDead);
regGlobal('keepCapture', jsKeepCapture);
regGlobal('releaseCapture', jsReleaseCapture);
regGlobal('setScreenScale', jsSetScreenScale);
regGlobal('snapShot', jsSnapShot);
regGlobal('ocrText', jsOcrText);
regGlobal('findImage', jsFindImage);
regGlobal('findPic', jsFindPic);
regGlobal('findPicEx', jsFindPicEx);
regGlobal('findPicFast', jsImageStub2);
regGlobal('findPicAllPoint', jsFindPicAllPoint);
regGlobal('findCircle', jsFindCircle);

// ---- 节点选择器（41 全局工厂）----
for (const spec of SELECTOR_SPECS) {
  regGlobal(spec.fn, (L) => jsSelStarter(L, spec));
}

// ---- 设备信息 ----
regGlobal('getDisplaySize', jsGetDisplaySize);
regGlobal('getDisplayInfo', jsGetDisplayInfo);
regGlobal('getCpuArch', jsGetCpuArch);
regGlobal('getDisplayDpi', jsInt0('getDisplayDpi'));
regGlobal('getBatteryLevel', jsInt0('getBatteryLevel'));
regGlobal('getSdkVersion', jsInt0('getSdkVersion'));
regGlobal('getDisplayRotate', jsInt0('getDisplayRotate'));
['getSdPath', 'getDeviceId', 'getBrand', 'getBootLoader', 'getBoard', 'getManufacturer', 'getProduct', 'getDevice', 'getModel', 'getHardware', 'getId', 'getFingerprint', 'getCpuAbi', 'getCpuAbi2', 'getOsVersionName', 'getWifiMac', 'getPackageName', 'getSubscriberId', 'getSimSerialNumber'].forEach((n) => regGlobal(n, jsStr0(n)));

// ---- 应用管理 ----
regGlobal('runApp', jsRunApp);
regGlobal('stopApp', jsStopApp);
regGlobal('getInstalledApk', jsGetInstalledApk);
regGlobal('frontAppName', jsFrontAppName);
regGlobal('appIsFront', jsAppIsFront);
regGlobal('appIsRunning', jsAppIsRunning);
regGlobal('getCurrentActivity', jsGetCurrentActivity);
regGlobal('readPasteboard', jsReadPasteboard);
regGlobal('writePasteboard', jsWritePasteboard);
regGlobal('phoneCall', jsPhoneCall);
regGlobal('runIntent', jsRunIntent);
regGlobal('installApk', jsInstallApk);

// ---- 系统控制 ----
regGlobal('setControlBarPosNew', jsSetControlBarPosNew);
regGlobal('showControlBar', jsShowControlBar);
regGlobal('restartScript', jsRestartScript);
regGlobal('setStopCallBack', jsSetStopCallBack);
regGlobal('vibrate', jsVibrate);
regGlobal('playAudio', (L) => { console.log('[system] playAudio (PC 宿主未实现)'); return 0; });
regGlobal('stopAudio', (L) => { return 0; });
regGlobal('rnd', jsRnd);
regGlobal('exec', jsExec);
regGlobal('sleep', jsSleep);
regGlobal('lockScreen', jsLockScreen);
regGlobal('unLockScreen', jsUnLockScreen);
regGlobal('setBTEnable', jsSetBTEnable);
regGlobal('setWifiEnable', jsSetWifiEnable);
regGlobal('setAirplaneMode', jsSetAirplaneMode);
regGlobal('getRunEnvType', jsGetRunEnvType);
regGlobal('exitScript', jsExitScript);

// ---- 交互 ----
regGlobal('toast', jsToast);
regGlobal('hideToast', jsHideToast);
regGlobal('showUI', jsShowUI);
regGlobal('showUIEx', jsShowUIEx);
regGlobal('createHUD', jsCreateHUD);
regGlobal('showHUD', jsShowHUD);
regGlobal('hideHUD', jsHideHUD);

// ---- touch 别名表（兼容旧脚本写法）----
setField('touch', 'tap', jsTap);
setField('touch', 'swipe', jsSwipe);
setField('touch', 'longTap', jsLongTap);
setField('touch', 'touchDown', jsTouchDown);
setField('touch', 'touchMove', jsTouchMove);
setField('touch', 'touchMoveEx', jsTouchMoveEx);
setField('touch', 'touchUp', jsTouchUp);
setField('touch', 'inputText', jsInputText);
setField('touch', 'keyPress', jsKeyPress);
setField('touch', 'keyDown', jsKeyDown);
setField('touch', 'keyUp', jsKeyUp);

// ---- nodeLib / imeLib / ui / cipher / network / json 模块表 ----
setField('nodeLib', 'getNodeXml', (L) => { const x = bridge.nodeXml(); lua.lua_pushstring(L, to_luastring(x || '')); return 1; });
setField('nodeLib', 'saveNode', (L) => { console.log('[nodeLib] saveNode (PC 宿主未实现)'); lua.lua_pushboolean(L, 0); return 1; });
setField('nodeLib', 'saveNodeNew', (L) => { console.log('[nodeLib] saveNodeNew (PC 宿主未实现)'); lua.lua_pushboolean(L, 0); return 1; });
setField('nodeLib', 'lockNode', (L) => { console.log('[nodeLib] lockNode (PC 宿主未实现)'); lua.lua_pushboolean(L, 0); return 1; });
setField('nodeLib', 'unlockNode', (L) => { console.log('[nodeLib] unlockNode (PC 宿主未实现)'); lua.lua_pushboolean(L, 0); return 1; });
setField('nodeLib', 'openAccessibility', (L) => { console.log('[nodeLib] openAccessibility (PC 宿主未实现)'); lua.lua_pushboolean(L, 0); return 1; });
setField('nodeLib', 'closeAccessibility', (L) => { console.log('[nodeLib] closeAccessibility (PC 宿主未实现)'); lua.lua_pushboolean(L, 0); return 1; });

setField('imeLib', 'lock', (L) => { console.log('[imeLib] lock (PC 宿主未实现)'); lua.lua_pushboolean(L, 0); return 1; });
setField('imeLib', 'unlock', (L) => { console.log('[imeLib] unlock (PC 宿主未实现)'); lua.lua_pushboolean(L, 0); return 1; });
setField('imeLib', 'setText', (L) => { bridge.inputText(str(L, 1)); lua.lua_pushboolean(L, 1); return 1; });
setField('imeLib', 'deleteChar', (L) => { console.log('[imeLib] deleteChar (PC 宿主未实现)'); lua.lua_pushboolean(L, 0); return 1; });
setField('imeLib', 'finishInput', (L) => { lua.lua_pushboolean(L, 1); return 1; });
setField('imeLib', 'keyEvent', (L) => { const act = num(L, 1), code = num(L, 2); if (act === 0) bridge.keyDown(code); else bridge.keyUp(code); lua.lua_pushboolean(L, 1); return 1; });

setField('ui', 'newLayout', (L) => { console.log('[ui] newLayout (PC 宿主无 UI 引擎)'); return 0; });
setField('ui', 'addButton', (L) => { console.log('[ui] addButton (PC 宿主无 UI 引擎)'); return 0; });
setField('ui', 'addEditText', (L) => { console.log('[ui] addEditText (PC 宿主无 UI 引擎)'); return 0; });
setField('ui', 'addTextView', (L) => { console.log('[ui] addTextView (PC 宿主无 UI 引擎)'); return 0; });
setField('ui', 'addCheckBox', (L) => { console.log('[ui] addCheckBox (PC 宿主无 UI 引擎)'); return 0; });
setField('ui', 'addRadioBox', (L) => { console.log('[ui] addRadioBox (PC 宿主无 UI 引擎)'); return 0; });
setField('ui', 'addComboBox', (L) => { console.log('[ui] addComboBox (PC 宿主无 UI 引擎)'); return 0; });
setField('ui', 'setOnClick', (L) => { console.log('[ui] setOnClick (PC 宿主无 UI 引擎)'); return 0; });
setField('ui', 'show', (L) => { console.log('[ui] show (PC 宿主无 UI 引擎)'); return 0; });

setField('cipher', 'md5', (L) => { lua.lua_pushstring(L, to_luastring(crypto.createHash('md5').update(str(L, 1)).digest('hex'))); return 1; });
setField('cipher', 'sha1', (L) => { lua.lua_pushstring(L, to_luastring(crypto.createHash('sha1').update(str(L, 1)).digest('hex'))); return 1; });
setField('cipher', 'base64', (L) => {
  const s = str(L, 1); const decode = lua.lua_toboolean(L, 2);
  if (decode) { try { lua.lua_pushstring(L, to_luastring(Buffer.from(s, 'base64').toString('utf8'))); } catch (e) { lua.lua_pushnil(L); } }
  else lua.lua_pushstring(L, to_luastring(Buffer.from(s, 'utf8').toString('base64')));
  return 1;
});
setField('cipher', 'aes', (L) => { console.log('[cipher] aes (PC 宿主未实现)'); lua.lua_pushnil(L); return 1; });

function curl(args) {
  try { return execFileSync(CURL, args, { encoding: 'utf8', timeout: 15000, stdio: ['ignore', 'pipe', 'ignore'] }); }
  catch (e) { console.error('[net] curl 失败:', e.message); return null; }
}
setField('network', 'httpGet', (L) => { const b = curl(['-s', '-L', str(L, 1)]); if (b == null) lua.lua_pushnil(L); else lua.lua_pushstring(L, to_luastring(b)); return 1; });
setField('network', 'httpPost', (L) => { const b = curl(['-s', '-L', '-X', 'POST', '-d', str(L, 2), str(L, 1)]); if (b == null) lua.lua_pushnil(L); else lua.lua_pushstring(L, to_luastring(b)); return 1; });
setField('network', 'download', (L) => { curl(['-s', '-L', '-o', str(L, 2), str(L, 1)]); lua.lua_pushstring(L, to_luastring(str(L, 2))); return 1; });

// ---- 全局网络函数（P0 风格：httpGet/httpPost -> body, code；downloadFile(url,path) -> 0/1）----
function httpWithCode(args) {
  const out = curl(args.concat(['-w', '\n__HTTP_CODE__:%{http_code}']));
  if (out == null) return [null, 0];
  const m = out.match(/\n__HTTP_CODE__:(\d+)\s*$/);
  if (!m) return [out, 0];
  return [out.slice(0, m.index), parseInt(m[1], 10)];
}
function jsHttpGet(L) {
  const url = str(L, 1), timeout = num(L, 2, 30);
  const [body, code] = httpWithCode(['-s', '-L', '-m', String(timeout), url]);
  if (body == null) { lua.lua_pushnil(L); lua.lua_pushinteger(L, 0); }
  else { lua.lua_pushstring(L, to_luastring(body)); lua.lua_pushinteger(L, code); }
  return 2;
}
function jsHttpPost(L) {
  const url = str(L, 1), data = str(L, 2), timeout = num(L, 3, 30);
  const [body, code] = httpWithCode(['-s', '-L', '-m', String(timeout), '-X', 'POST', '-d', data, url]);
  if (body == null) { lua.lua_pushnil(L); lua.lua_pushinteger(L, 0); }
  else { lua.lua_pushstring(L, to_luastring(body)); lua.lua_pushinteger(L, code); }
  return 2;
}
function jsDownloadFile(L) {
  const url = str(L, 1), p = str(L, 2);
  const [body, code] = httpWithCode(['-s', '-L', '-m', '120', '-o', p, url]);
  lua.lua_pushinteger(L, (code >= 200 && code < 400) ? 0 : 1);
  return 1;
}
regGlobal('httpGet', jsHttpGet);
regGlobal('httpPost', jsHttpPost);
regGlobal('downloadFile', jsDownloadFile);

// ---- jsonLib.* 别名 + 全局编码函数（P0 风格）----
setField('jsonLib', 'encode', (L) => { const v = luaValToJs(L, 1); lua.lua_pushstring(L, to_luastring(JSON.stringify(v))); return 1; });
setField('jsonLib', 'decode', (L) => { try { pushJsToLua(L, JSON.parse(str(L, 1))); } catch (e) { lua.lua_pushnil(L); } return 1; });
regGlobal('MD5', (L) => { lua.lua_pushstring(L, to_luastring(crypto.createHash('md5').update(str(L, 1)).digest('hex'))); return 1; });
regGlobal('encodeBase64', (L) => { lua.lua_pushstring(L, to_luastring(Buffer.from(str(L, 1), 'utf8').toString('base64'))); return 1; });
regGlobal('decodeBase64', (L) => { try { lua.lua_pushstring(L, to_luastring(Buffer.from(str(L, 1), 'base64').toString('utf8'))); } catch (e) { lua.lua_pushnil(L); } return 1; });

setField('json', 'encode', (L) => { const v = luaValToJs(L, 1); lua.lua_pushstring(L, to_luastring(JSON.stringify(v))); return 1; });
setField('json', 'decode', (L) => { try { pushJsToLua(L, JSON.parse(str(L, 1))); } catch (e) { console.error('[json] decode 失败:', e.message); lua.lua_pushnil(L); } return 1; });

// ---- console ----
setField('console', 'log', (L) => {
  const n = lua.lua_gettop(L); const parts = [];
  for (let i = 1; i <= n; i++) {
    if (lua.lua_isstring(L, i)) parts.push(str(L, i));
    else if (lua.lua_isnumber(L, i)) parts.push(String(lua.lua_tonumber(L, i)));
    else parts.push('(' + to_jsstring(lua.lua_typename(L, lua.lua_type(L, i))) + ')');
  }
  console.log(parts.join('\t')); return 0;
});
lua.lua_pushcfunction(L, (L2) => {
  const n = lua.lua_gettop(L2); const parts = [];
  for (let i = 1; i <= n; i++) parts.push(lua.lua_isstring(L2, i) ? str(L2, i) : (lua.lua_isnumber(L2, i) ? String(lua.lua_tonumber(L2, i)) : ''));
  console.log(parts.join('\t')); return 0;
});
lua.lua_setglobal(L, to_luastring('log'));

console.log(`[MatisuAuto] 目标设备: ${bridge.CFG.target} (${bridge.getModel()})  runEnv=${bridge.getRunEnvType()}`);

// ============================================================
// 运行用户脚本
// ============================================================
const scriptArg = process.argv[2];
const userPath = scriptArg ? path.resolve(process.cwd(), scriptArg) : path.join(__dirname, 'demo.lua');
const userCode = fs.readFileSync(userPath, 'utf8');
for (;;) {
  console.log(`\n===== 运行 ${path.basename(userPath)} =====`);
  const status = lauxlib.luaL_dostring(L, to_luastring(userCode));
  if (status !== 0) {
    const err = to_jsstring(lua.lua_tostring(L, -1));
    if (restartFlag && /__MATISU_RESTART__/.test(err)) {
      restartFlag = false;
      console.log('===== restartScript：重跑脚本 =====');
      continue;
    }
    console.error('脚本运行错误:', err);
    callStopCb();
    process.exit(1);
  }
  break;
}
callStopCb();
console.log('===== 脚本结束 =====');
lua.lua_close(L);
