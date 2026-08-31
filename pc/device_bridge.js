'use strict';
/*
 * MatisuAuto 设备桥接层 —— 对齐「懒人精灵 高级版 2.0.1」真实 API
 *
 * 职责：把懒人精灵的函数语义翻译成真实设备指令。
 *   - Android : adb（input / sendevent / dumpsys / getprop）+ android_cap.py（图色 & 节点）
 *   - iOS     : TCP 文本协议 -> 设备侧 ControlServer.mm（触控已通，图色/节点待 Phase 3）
 *
 * 目标选择：devices.json 的 target，或环境变量 MATISU_TARGET（ios | android，环境变量优先）。
 * 全部同步实现 —— fengari 的 Lua C 回调不能穿透异步。
 *
 * === 两个关键实现说明 ===
 * 1) 颜色格式是 BBGGRR（懒人精灵图色系约定），解析在 android_cap.py 里，本层只透传字符串。
 * 2) touchDown/touchMove/touchUp 是真正的多指：走 root + sendevent 的 Linux 多点协议 B
 *    （ABS_MT_SLOT / ABS_MT_TRACKING_ID / BTN_TOUCH）。这与懒人精灵文档「此函数只能在激活或
 *    root 模式下使用」完全一致。无 root 时降级为 input swipe 合成路径。
 */

const { execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const PY = 'C:/Users/Administrator/.workbuddy/binaries/python/envs/default/Scripts/python.exe';
const CAP = path.join(__dirname, 'android_cap.py');
const IOS_SOCK = path.join(__dirname, 'ios_sock.py');

// ============================================================ 配置

function loadConfig() {
  const cfg = {
    target: 'android',
    ios: { host: '192.69.0.38', port: 18182, w: 375, h: 667, name: 'iPhone SE2 (iOS 16.1.1)' },
    android: {
      host: '192.69.0.18', port: 5555, w: 1280, h: 720, name: 'Android Emulator',
      adb: 'C:/Users/Administrator/.qoderworkcn/workspace/mqsshftg3n38hfyc/android-sdk/platform-tools/adb.exe',
      device: '192.69.0.18:5555',
    },
  };
  try {
    const p = path.join(__dirname, 'devices.json');
    if (fs.existsSync(p)) {
      const u = JSON.parse(fs.readFileSync(p, 'utf8'));
      if (u.target) cfg.target = u.target;
      if (u.ios) Object.assign(cfg.ios, u.ios);
      if (u.android) Object.assign(cfg.android, u.android);
    }
  } catch (e) { /* 配置损坏则沿用默认 */ }
  if (process.env.MATISU_TARGET) cfg.target = process.env.MATISU_TARGET;
  if (process.env.MATISU_IOS_HOST) cfg.ios.host = process.env.MATISU_IOS_HOST;
  if (process.env.MATISU_IOS_PORT) cfg.ios.port = parseInt(process.env.MATISU_IOS_PORT, 10) || cfg.ios.port;
  return cfg;
}
const CFG = loadConfig();
const isAndroid = () => CFG.target === 'android';

function warn(fn, msg) { console.error(`[bridge][${fn}] ${msg}`); }

function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, Math.max(0, ms | 0));
}

// ============================================================ adb 原语

/** 执行 adb，返回 stdout 字符串；失败返回 null。 */
function adbOut(args, timeout = 15000) {
  try {
    return execFileSync(CFG.android.adb, ['-s', CFG.android.device, ...args.map(String)],
      { encoding: 'utf8', timeout, stdio: ['ignore', 'pipe', 'ignore'] });
  } catch (e) { return null; }
}

/** 执行 adb，只关心成败。 */
function adbRun(args, timeout = 15000) {
  try {
    execFileSync(CFG.android.adb, ['-s', CFG.android.device, ...args.map(String)],
      { stdio: 'ignore', timeout });
    return true;
  } catch (e) { warn('adb', `失败: ${args.join(' ')} :: ${e.message}`); return false; }
}

/** 设备侧 shell（整条命令作为单个 arg 交给 adb，由设备 shell 解析引号）。 */
function sh(cmd, timeout = 15000) { return adbOut(['shell', cmd], timeout); }

/** 设备侧 root shell。 */
function suSh(cmd, timeout = 15000) { return adbOut(['shell', `su -c '${cmd}'`], timeout); }

let _hasRoot = null;
function hasRoot() {
  if (_hasRoot !== null) return _hasRoot;
  if (!isAndroid()) return (_hasRoot = false);
  const r = suSh('id', 8000);
  _hasRoot = !!(r && /uid=0\(root\)/.test(r));
  return _hasRoot;
}

let _prop = {};
function prop(name) {
  if (!isAndroid()) return '';
  if (_prop[name] !== undefined) return _prop[name];
  const v = (sh(`getprop ${name}`, 8000) || '').trim();
  _prop[name] = v;
  return v;
}

// ============================================================ iOS 通道

function iosRun(args) {
  try {
    execFileSync(PY, [path.join(__dirname, 'ios_client.py'), ...args.map(String)],
      { stdio: 'ignore', timeout: 8000 });
    return true;
  } catch (e) { warn('ios', `指令失败: ${args.join(' ')} :: ${e.message}`); return false; }
}

// ============================================================ 屏幕尺寸 / setScreenScale

let _real = null;
/** 设备真实分辨率（物理像素），与 screencap / sendevent 坐标空间一致。 */
function realSize() {
  if (_real) return _real;
  if (!isAndroid()) {
    const inf = iosInfo();
    _real = [inf.width || CFG.ios.w, inf.height || CFG.ios.h];
    return _real;
  }
  const s = sh('wm size', 8000) || '';
  const m = s.match(/Override size:\s*(\d+)x(\d+)/) || s.match(/Physical size:\s*(\d+)x(\d+)/);
  _real = m ? [parseInt(m[1], 10), parseInt(m[2], 10)] : [CFG.android.w, CFG.android.h];
  return _real;
}

/**
 * setScreenScale(type,width,height,[scale])
 *   type 0=关闭 1=开启；width/height=脚本开发时的分辨率
 *   scale 0=只缩放「传入」坐标，函数返回的坐标保持设备真实值
 *         1=传入缩放 + 返回反向缩放（默认）
 */
const SC = { on: false, dw: 0, dh: 0, mode: 1 };
function setScreenScale(type, w, h, scale) {
  SC.on = (Number(type) === 1);
  SC.dw = Number(w) || 0;
  SC.dh = Number(h) || 0;
  SC.mode = (scale === undefined || scale === null) ? 1 : (Number(scale) || 0);
  return true;
}
// 开发坐标 -> 设备真实坐标
function ix(x) { if (!SC.on || !SC.dw) return Math.round(x); const [rw] = realSize(); return Math.round(x * rw / SC.dw); }
function iy(y) { if (!SC.on || !SC.dh) return Math.round(y); const [, rh] = realSize(); return Math.round(y * rh / SC.dh); }
// 设备真实坐标 -> 开发坐标（仅 mode=1 时反向缩放）
function ox(x) { if (!SC.on || SC.mode !== 1 || !SC.dw) return x; const [rw] = realSize(); return Math.round(x * SC.dw / rw); }
function oy(y) { if (!SC.on || SC.mode !== 1 || !SC.dh) return y; const [, rh] = realSize(); return Math.round(y * SC.dh / rh); }

// ============================================================ 触控：sendevent 多指通道

// Linux input 事件常量
const EV_SYN = 0, EV_KEY = 1, EV_ABS = 3;
const SYN_REPORT = 0;
const BTN_TOUCH = 0x14a;        // 330
const ABS_MT_SLOT = 0x2f;       // 47
const ABS_MT_POSITION_X = 0x35; // 53
const ABS_MT_POSITION_Y = 0x36; // 54
const ABS_MT_TRACKING_ID = 0x39;// 57
const ABS_MT_PRESSURE = 0x3a;   // 58

let _touchDev = null;
/**
 * 探测触摸屏 event 设备与其 ABS 量程。
 * 认定条件：同时具备 ABS_MT_POSITION_X / Y。量程用于把屏幕像素映射到触摸面坐标。
 */
function touchDev() {
  if (_touchDev !== undefined && _touchDev !== null) return _touchDev;
  _touchDev = false;
  if (!isAndroid()) return _touchDev;
  const raw = sh('getevent -pl', 20000);
  if (!raw) return _touchDev;
  // 按 "add device N: /dev/input/eventX" 切块
  const blocks = raw.split(/add device \d+:\s*/).slice(1);
  for (const b of blocks) {
    const dev = (b.match(/^(\/dev\/input\/event\d+)/) || [])[1];
    if (!dev) continue;
    const mx = b.match(/ABS_MT_POSITION_X\s*:\s*value \d+, min (-?\d+), max (-?\d+)/);
    const my = b.match(/ABS_MT_POSITION_Y\s*:\s*value \d+, min (-?\d+), max (-?\d+)/);
    if (!mx || !my) continue;
    _touchDev = {
      dev,
      xmin: +mx[1], xmax: +mx[2],
      ymin: +my[1], ymax: +my[2],
      slot: /ABS_MT_SLOT/.test(b),          // true = 多点协议 B
      pressureMax: (b.match(/ABS_MT_PRESSURE\s*:\s*value \d+, min -?\d+, max (-?\d+)/) || [, 1])[1] | 0,
    };
    break;
  }
  return _touchDev;
}

/** 屏幕像素 -> 触摸面坐标 */
function toPanel(x, y, td) {
  const [rw, rh] = realSize();
  const px = td.xmin + Math.round((Math.max(0, Math.min(x, rw - 1)) / (rw - 1)) * (td.xmax - td.xmin));
  const py = td.ymin + Math.round((Math.max(0, Math.min(y, rh - 1)) / (rh - 1)) * (td.ymax - td.ymin));
  return [px, py];
}

/** 一次 adb 往返批量发 sendevent（逐条发太慢：每条约 60-100ms）。 */
function sendEvents(lines) {
  const td = touchDev();
  if (!td) return false;
  const cmd = lines.map(([t, c, v]) => `sendevent ${td.dev} ${t} ${c} ${v}`).join(';');
  return suSh(cmd, 20000) !== null;
}

// 手指状态：id -> {x, y, tracking, down}
const _fingers = {};
let _trackSeq = 100;

function evDown(id, x, y, td) {
  const [px, py] = toPanel(x, y, td);
  const tid = ++_trackSeq;
  _fingers[id] = { x, y, tracking: tid, down: true };
  const ev = [];
  if (td.slot) ev.push([EV_ABS, ABS_MT_SLOT, id]);
  ev.push([EV_ABS, ABS_MT_TRACKING_ID, tid]);
  ev.push([EV_ABS, ABS_MT_POSITION_X, px]);
  ev.push([EV_ABS, ABS_MT_POSITION_Y, py]);
  if (td.pressureMax > 0) ev.push([EV_ABS, ABS_MT_PRESSURE, Math.min(1, td.pressureMax)]);
  if (Object.keys(_fingers).length === 1) ev.push([EV_KEY, BTN_TOUCH, 1]);
  ev.push([EV_SYN, SYN_REPORT, 0]);
  return ev;
}

function evMove(id, x, y, td) {
  const f = _fingers[id];
  if (!f) return [];
  const [px, py] = toPanel(x, y, td);
  f.x = x; f.y = y;
  const ev = [];
  if (td.slot) ev.push([EV_ABS, ABS_MT_SLOT, id]);
  ev.push([EV_ABS, ABS_MT_POSITION_X, px]);
  ev.push([EV_ABS, ABS_MT_POSITION_Y, py]);
  ev.push([EV_SYN, SYN_REPORT, 0]);
  return ev;
}

function evUp(id, td) {
  if (!_fingers[id]) return [];
  delete _fingers[id];
  const ev = [];
  if (td.slot) ev.push([EV_ABS, ABS_MT_SLOT, id]);
  ev.push([EV_ABS, ABS_MT_TRACKING_ID, -1]);
  if (Object.keys(_fingers).length === 0) ev.push([EV_KEY, BTN_TOUCH, 0]);
  ev.push([EV_SYN, SYN_REPORT, 0]);
  return ev;
}

// —— 无 root 时的降级：累积路径，抬起时用 input swipe 合成
const _synth = {};

// ============================================================ 触控 API（懒人精灵语义）

function tap(x, y) {
  const X = ix(x), Y = iy(y);
  if (!isAndroid()) return iosRun(['tap', X, Y]);
  return adbRun(['shell', 'input', 'tap', X, Y]);
}

function longTap(x, y, ms) {
  const X = ix(x), Y = iy(y);
  const dur = ms == null ? 800 : Math.max(1, ms | 0);
  if (!isAndroid()) { iosRun(['down', 0, X, Y]); sleepSync(dur); return iosRun(['up', 0, X, Y]); }
  // input swipe 起终点相同 + 时长 = 长按
  return adbRun(['shell', 'input', 'swipe', X, Y, X, Y, dur]);
}

function swipe(x1, y1, x2, y2, time) {
  const a = ix(x1), b = iy(y1), c = ix(x2), d = iy(y2);
  const dur = time == null ? 300 : Math.max(1, time | 0);  // 懒人精灵单位为毫秒
  if (!isAndroid()) return iosRun(['swipe', a, b, c, d, dur / 1000]);
  return adbRun(['shell', 'input', 'swipe', a, b, c, d, dur]);
}

// iOS 各手指最后落点：touchUp 省略 x/y 时必须在原位抬起，否则会变成到 (0,0) 的误滑动
const _iosLast = {};

function touchDown(id, x, y) {
  const X = ix(x), Y = iy(y);
  if (!isAndroid()) { _iosLast[id | 0] = [X, Y]; return iosRun(['down', id, X, Y]); }
  const td = touchDev();
  if (td && hasRoot()) return sendEvents(evDown(id | 0, X, Y, td));
  _synth[id] = [[X, Y]];
  return true;
}

function touchMove(id, x, y) {
  const X = ix(x), Y = iy(y);
  if (!isAndroid()) { _iosLast[id | 0] = [X, Y]; return iosRun(['move', id, X, Y]); }
  const td = touchDev();
  if (td && hasRoot()) return sendEvents(evMove(id | 0, X, Y, td));
  if (_synth[id]) _synth[id].push([X, Y]);
  return true;
}

/** touchMoveEx(id,x,y,time)：在 time 毫秒内平滑移动到目标点。 */
function touchMoveEx(id, x, y, time) {
  const X = ix(x), Y = iy(y);
  const dur = Math.max(1, (time == null ? 300 : time) | 0);
  if (!isAndroid()) { _iosLast[id | 0] = [X, Y]; iosRun(['move', id, X, Y]); sleepSync(dur); return true; }
  const td = touchDev();
  if (td && hasRoot()) {
    const f = _fingers[id | 0];
    if (!f) return false;
    const steps = Math.max(2, Math.min(60, Math.round(dur / 16)));
    const sx = f.x, sy = f.y;
    const ev = [];
    for (let i = 1; i <= steps; i++) {
      const t = i / steps;
      ev.push(...evMove(id | 0, Math.round(sx + (X - sx) * t), Math.round(sy + (Y - sy) * t), td));
    }
    // 一次往返发完全部中间点，再按剩余时间补齐节奏
    const t0 = Date.now();
    const ok = sendEvents(ev);
    const left = dur - (Date.now() - t0);
    if (left > 0) sleepSync(left);
    return ok;
  }
  if (_synth[id]) _synth[id].push([X, Y]);
  sleepSync(dur);
  return true;
}

function touchUp(id, x, y) {
  if (!isAndroid()) {
    // 官方 touchUp 既支持 touchUp(id) 也支持 touchUp(id,x,y)；省略坐标时在该指最后落点抬起
    const last = _iosLast[id | 0] || [0, 0];
    const X = (x == null) ? last[0] : ix(x);
    const Y = (y == null) ? last[1] : iy(y);
    delete _iosLast[id | 0];
    return iosRun(['up', id, X, Y]);
  }
  const td = touchDev();
  if (td && hasRoot()) return sendEvents(evUp(id | 0, td));
  // 降级：把累积路径合成一次 swipe（或单点 tap）
  const p = _synth[id];
  delete _synth[id];
  if (!p || !p.length) return false;
  const s = p[0], e = p[p.length - 1];
  if (p.length === 1 || (s[0] === e[0] && s[1] === e[1])) return adbRun(['shell', 'input', 'tap', s[0], s[1]]);
  return adbRun(['shell', 'input', 'swipe', s[0], s[1], e[0], e[1], Math.max(50, p.length * 8)]);
}

// —— 按键
const KEYMAP = {
  home: 3, back: 4, recent: 187, call: 5, endcall: 6, volup: 24, voldown: 25,
  power: 26, camera: 27, menu: 82, pageup: 92, pagedown: 93,
};
// Android keycode -> Linux input code（keyDown/keyUp 走 sendevent 才能"按住不放"）
const LINUX_KEY = { 3: 172, 4: 158, 5: 169, 6: 170, 24: 115, 25: 114, 26: 116, 27: 212, 82: 139 };

function keyCode(code) {
  if (typeof code === 'number') return code | 0;
  const k = String(code).trim().toLowerCase();
  if (KEYMAP[k] !== undefined) return KEYMAP[k];
  const n = parseInt(k, 10);
  return isNaN(n) ? 0 : n;
}

// iOS 键名映射（原版风格小写键名 -> STHID/DOM 键名）
const IOS_KEY_NAMES = {
  home: 'HOME', return: 'RETURN', enter: 'RETURN', delete: 'DELETE_OR_BACKSPACE',
  backspace: 'DELETE_OR_BACKSPACE', escape: 'ESCAPE', esc: 'ESCAPE', tab: 'TAB',
  space: 'SPACE', left: 'LEFTARROW', right: 'RIGHTARROW', up: 'UPARROW', down: 'DOWNARROW',
};
function keyPress(code) {
  const c = keyCode(code);
  if (!isAndroid()) {
    const name = IOS_KEY_NAMES[String(code).toLowerCase()] || String(code).toUpperCase();
    const r = iosSock('key ' + name);
    return r !== null && r !== undefined;
  }
  return adbRun(['shell', 'input', 'keyevent', c]);
}

function keyRaw(code, down) {
  const c = keyCode(code);
  const lk = LINUX_KEY[c];
  const td = touchDev();
  if (!lk || !td || !hasRoot()) {
    warn(down ? 'keyDown' : 'keyUp', '需要 root + 可映射按键，已降级为 keyPress');
    return down ? adbRun(['shell', 'input', 'keyevent', c]) : true;
  }
  return sendEvents([[EV_KEY, lk, down ? 1 : 0], [EV_SYN, SYN_REPORT, 0]]);
}
function keyDown(code) { return keyRaw(code, true); }
function keyUp(code) { return keyRaw(code, false); }

/** inputText：ASCII 走 input text；含非 ASCII 时尝试 ADBKeyboard 广播。 */
function inputText(text) {
  const s = String(text == null ? '' : text);
  if (!isAndroid()) {
    // iOS：HID 键盘逐键注入（仅 ASCII；中文待设备端 imeLib）
    if (!/^[\x20-\x7e]*$/.test(s)) { warn('inputText', 'iOS 暂仅支持 ASCII 文本（中文待 imeLib）'); return false; }
    const r = iosSock('input ' + s);
    return r !== null && r !== undefined;
  }
  if (/^[\x20-\x7e]*$/.test(s)) {
    const esc = s.replace(/ /g, '%s').replace(/([()<>|;&*\\~"'`$])/g, '\\$1');
    return adbRun(['shell', 'input', 'text', esc]);
  }
  // 非 ASCII：input text 无法处理，尝试 ADBKeyboard（com.android.adbkeyboard）
  const b64 = Buffer.from(s, 'utf8').toString('base64');
  const r = sh(`am broadcast -a ADB_INPUT_B64 --es msg '${b64}'`, 8000);
  if (r && /result=0|Broadcast completed/.test(r)) return true;
  warn('inputText', `含非 ASCII，需设备安装 ADBKeyboard 输入法；文本="${s}"`);
  return false;
}

function setOnTouchListener() {
  warn('setOnTouchListener', 'PC 宿主无法监听设备触摸（需设备侧常驻服务），未实现');
  return false;
}

// ============================================================ Python 图色/节点通道

function pyCap(sub, req) {
  if (!isAndroid()) { warn(sub, 'iOS 图色/节点待 Phase 3 设备侧截图通道'); return null; }
  let tmp = null;
  try {
    const env = { ...process.env, MATISU_ADB: CFG.android.adb, MATISU_DEVICE: CFG.android.device };
    const args = [CAP, sub];
    if (req !== undefined) {
      tmp = path.join(os.tmpdir(), `matisu_req_${process.pid}_${Date.now()}.json`);
      fs.writeFileSync(tmp, JSON.stringify(req), 'utf8');
      args.push(tmp);
    }
    const out = execFileSync(PY, args, { encoding: 'utf8', timeout: 120000, env, stdio: ['ignore', 'pipe', 'pipe'] });
    const r = JSON.parse(out.trim());
    if (r && r.error) warn(sub, r.error);
    return r;
  } catch (e) {
    warn(sub, `cap 失败: ${e.message}`);
    return null;
  } finally {
    if (tmp) { try { fs.unlinkSync(tmp); } catch (_) {} }
  }
}

/** 把开发坐标区域换算成设备真实区域；[0,0,0,0] 表示全屏，原样透传。 */
function inReg(x1, y1, x2, y2) {
  const a = [x1 | 0, y1 | 0, x2 | 0, y2 | 0];
  if (a[0] === 0 && a[1] === 0 && a[2] === 0 && a[3] === 0) return a;
  return [ix(a[0]), iy(a[1]), ix(a[2]), iy(a[3])];
}

// —— 图色
function keepCapture() { if (!isAndroid()) return iosKeepCapture(); return !!pyCap('keepcapture', {}); }
function releaseCapture() { if (!isAndroid()) return iosReleaseCapture(); return !!pyCap('releasecapture', {}); }

/** findColor -> [ret, x, y]；未找到 [-1,-1,-1] */
function findColor(x1, y1, x2, y2, color, dir, sim) {
  if (!isAndroid()) return iosFindColor(x1, y1, x2, y2, color, dir, sim);
  const r = pyCap('findcolor', { reg: inReg(x1, y1, x2, y2), color: String(color), dir: dir | 0, sim: sim == null ? 0.9 : sim });
  if (!r || r.ret === undefined || r.ret < 0) return [-1, -1, -1];
  return [r.ret, ox(r.x), oy(r.y)];
}

/** findMultiColor -> [x, y]；未找到 [-1,-1] */
function findMultiColor(x1, y1, x2, y2, first, offset, dir, sim) {
  if (!isAndroid()) return iosFindMultiColor(x1, y1, x2, y2, first, offset, dir, sim);
  const r = pyCap('findmulticolor', { reg: inReg(x1, y1, x2, y2), first: String(first), offset: String(offset || ''), dir: dir | 0, sim: sim == null ? 0.9 : sim });
  if (!r || r.x === undefined || r.x < 0) return [-1, -1];
  return [ox(r.x), oy(r.y)];
}

/** findMultiColorAll -> [{x,y}, ...] */
function findMultiColorAll(x1, y1, x2, y2, first, offset, dir, sim) {
  if (!isAndroid()) return iosFindMultiColorAll(x1, y1, x2, y2, first, offset, dir, sim);
  const r = pyCap('findmulticolorall', { reg: inReg(x1, y1, x2, y2), first: String(first), offset: String(offset || ''), dir: dir | 0, sim: sim == null ? 0.9 : sim });
  if (!r || !Array.isArray(r.list)) return [];
  return r.list.map(p => ({ x: ox(p.x), y: oy(p.y) }));
}

function cmpColor(x, y, color, sim) {
  if (!isAndroid()) return iosCmpColor(x, y, color, sim);
  const r = pyCap('cmpcolor', { x: ix(x), y: iy(y), color: String(color), sim: sim == null ? 0.9 : sim });
  return r ? (r.ret | 0) : 0;
}

function cmpColorEx(multicolor, sim) {
  if (!isAndroid()) return iosCmpColorEx(multicolor, sim);
  // 多点串里的坐标同样需要按开发分辨率换算
  const fixed = String(multicolor).split(',').map(pt => {
    const a = pt.split('|');
    if (a.length < 3) return pt;
    return [ix(parseInt(a[0], 10)), iy(parseInt(a[1], 10)), ...a.slice(2)].join('|');
  }).join(',');
  const r = pyCap('cmpcolorex', { multicolor: fixed, sim: sim == null ? 0.9 : sim });
  return r ? (r.ret | 0) : 0;
}

function getColorNum(x1, y1, x2, y2, color, sim) {
  if (!isAndroid()) return iosGetColorNum(x1, y1, x2, y2, color, sim);
  const r = pyCap('getcolornum', { reg: inReg(x1, y1, x2, y2), color: String(color), sim: sim == null ? 0.9 : sim });
  return r ? (r.num | 0) : 0;
}

function colorDiff(c1, c2) {
  const [r1, g1, b1] = specRGB(c1);
  const [r2, g2, b2] = specRGB(c2);
  return Math.abs(r1 - r2) + Math.abs(g1 - g2) + Math.abs(b1 - b2);
}

/** colorToRGB -> [r,g,b]（纯计算，本地直接算，省一次进程往返） */
function colorToRGB(c) {
  const v = (typeof c === 'number') ? (c >>> 0) : parseInt(String(c).replace(/^0x/i, ''), 16);
  const n = (isNaN(v) ? 0 : v) & 0xFFFFFF;
  return [n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF];  // BBGGRR -> r,g,b
}

/** getPixelColor(x,y,[type])：type=1 返回整数，否则 16 进制字符串（均为 BBGGRR） */
function getPixelColor(x, y, type) {
  if (!isAndroid()) return iosGetPixelColor(x, y, type);
  const r = pyCap('getpixelcolor', { x: ix(x), y: iy(y), type: type | 0 });
  if (!r) return (type | 0) === 1 ? 0 : '000000';
  return r.color;
}

/** getScreenPixel -> [w, h, arr]（arr 为 BBGGRR 整数，行优先） */
function getScreenPixel(x1, y1, x2, y2) {
  if (!isAndroid()) return iosGetScreenPixel(x1, y1, x2, y2);
  const r = pyCap('getscreenpixel', { reg: inReg(x1, y1, x2, y2) });
  if (!r || r.w === undefined) return [-1, -1, []];
  return [r.w, r.h, r.arr || []];
}

function isDisplayDead(x1, y1, x2, y2, time) {
  if (!isAndroid()) return iosIsDisplayDead(x1, y1, x2, y2, time);
  const r = pyCap('isdisplaydead', { reg: inReg(x1, y1, x2, y2), time: time == null ? 5 : time });
  return r ? !!r.ret : true;
}

function snapShot(p, x1, y1, x2, y2) {
  if (!isAndroid()) return iosSnapShot(p, x1, y1, x2, y2);
  const reg = (x1 === undefined) ? [0, 0, 0, 0] : inReg(x1, y1, x2, y2);
  const r = pyCap('snapshot', { path: p, reg });
  return r ? (r.path || null) : null;
}

function ocrText(lang, x1, y1, x2, y2) {
  const r = pyCap('ocr', { lang: lang || 'chi_sim+eng', reg: (x1 === undefined) ? [0, 0, 0, 0] : inReg(x1, y1, x2, y2) });
  return r ? (r.text || '') : '';
}

// —— 节点
/**
 * nodeQuery(preds, mode, index)
 *   preds : [{k,v,m}]  k=id/text/desc/className/packageName/bounds/boundsInside/
 *                        drawingOrder/depth/index/布尔属性；m=eq|contains|startsWith|endsWith|matches
 *   mode  : one | once | all | index
 * 返回节点对象或数组，坐标已按 setScreenScale 反向换算。
 */
function nodeQuery(preds, mode, index, indexes) {
  if (!isAndroid()) return iosNodeQuery(preds, mode, index, indexes);
  const req = { preds: preds || [], mode: mode || 'all' };
  if (index !== undefined) req.index = index | 0;
  if (indexes !== undefined) req.indexes = indexes;
  const r = pyCap('getnodes', req);
  if (!r) return (mode === 'one' || mode === 'once') ? null : [];
  const fix = (n) => {
    if (!n) return null;
    n.left = ox(n.left); n.right = ox(n.right);
    n.top = oy(n.top); n.bottom = oy(n.bottom);
    n.cx = ox(n.cx); n.cy = oy(n.cy);
    return n;
  };
  if (r.node !== undefined) return fix(r.node);
  return (r.list || []).map(fix);
}

function nodeXml() {
  if (!isAndroid()) {
    const l = iosNodes();
    return l ? JSON.stringify(l) : null;
  }
  try {
    const env = { ...process.env, MATISU_ADB: CFG.android.adb, MATISU_DEVICE: CFG.android.device };
    return execFileSync(PY, [CAP, 'nodexml'], { encoding: 'utf8', timeout: 60000, env, stdio: ['ignore', 'pipe', 'ignore'] });
  } catch (e) { warn('nodeXml', e.message); return null; }
}

// ============================================================ iOS 图色/节点通道（TCP + 自解 PNG）
// 与 Android 的 android_cap.py 同构：经 ios_sock.py 同步连接设备 18182，
// screencap 收 PNG、uinode 收 JSON，然后在本进程内做图色匹配 / 节点过滤
// （算法 1:1 移植自 android_cap.py，保证与 Android 行为一致）。
// 坐标空间 = 逻辑点（points），与 touch / 节点点击一致；截图解码后缩放到 CFG.ios.w/h。

let iosFrame = null;                 // {w,h,data:Uint8Array RGBA}（已缩放到逻辑点）
let iosNodesCache = { ts: 0, list: [] };

function iosSock(cmd, outFile) {
  const env = { ...process.env, MATISU_IOS_HOST: CFG.ios.host, MATISU_IOS_PORT: String(CFG.ios.port) };
  const args = [IOS_SOCK, cmd];
  if (outFile) args.push(outFile);
  try {
    const out = execFileSync(PY, args, { encoding: 'buffer', timeout: 30000, env, stdio: ['ignore', 'pipe', 'ignore'] });
    // 有 outFile：负载已写入文件，返回成功布尔；无 outFile（如 uinode）：返回 stdout 缓冲
    return outFile ? true : out;
  } catch (e) { warn('ios', `${cmd} 失败: ${e.message}`); return null; }
}

// ---- iOS 真实设备信息（devinfo 指令，进程内缓存一次）----
let iosInfoCache = null;
function iosInfo() {
  if (iosInfoCache) return iosInfoCache;
  let obj = null;
  try {
    const out = iosSock('devinfo');
    if (out && out.length) obj = JSON.parse(out.toString('utf8'));
  } catch (e) { warn('ios', `devinfo 解析失败: ${e.message}`); }
  // 设备不支持 devinfo（旧版 App）时退回 devices.json 配置，保证脚本仍可跑
  iosInfoCache = obj || {
    name: CFG.ios.name, model: '', modelName: 'iPhone', systemName: 'iOS', systemVersion: '',
    sdk: 0, width: CFG.ios.w, height: CFG.ios.h, scale: 2,
    pixelWidth: CFG.ios.w * 2, pixelHeight: CFG.ios.h * 2, dpi: 326, rotate: 0,
    battery: -1, cpuAbi: 'arm64e', idfv: '', bundleId: '', _fallback: true,
  };
  return iosInfoCache;
}

// ---- 最小 PNG 解码（8bit, colorType 2=RGB / 6=RGBA）----
function decodePNG(buf) {
  if (!buf || buf.length < 8 || buf.readUInt32BE(0) !== 0x89504e47) { warn('png', 'PNG 签名无效'); return null; }
  let p = 8, w = 0, h = 0, ct = 0, bd = 0; const idat = [];
  while (p < buf.length) {
    const len = buf.readUInt32BE(p);
    const type = buf.toString('ascii', p + 4, p + 8);
    const data = buf.slice(p + 8, p + 8 + len);
    if (type === 'IHDR') { w = data.readUInt32BE(0); h = data.readUInt32BE(4); bd = data[8]; ct = data[9]; }
    else if (type === 'IDAT') idat.push(data);
    else if (type === 'IEND') break;
    p += 12 + len;
  }
  if (bd !== 8 || (ct !== 2 && ct !== 6)) { warn('png', `仅支持 8bit RGB/RGBA，实际 ct=${ct} bd=${bd}`); return null; }
  const ch = (ct === 6) ? 4 : 3;
  const zlib = require('zlib');
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = w * ch;
  const out = new Uint8Array(w * h * 4);
  const prev = new Uint8Array(stride);
  let rp = 0;
  for (let y = 0; y < h; y++) {
    const f = raw[rp++];
    const line = raw.slice(rp, rp + stride); rp += stride;
    const cur = new Uint8Array(stride);
    for (let x = 0; x < stride; x++) {
      const a = x >= ch ? cur[x - ch] : 0;
      const b = prev[x];
      const c = x >= ch ? prev[x - ch] : 0;
      let v = line[x];
      if (f === 1) v = (v + a) & 0xff;
      else if (f === 2) v = (v + b) & 0xff;
      else if (f === 3) v = (v + ((a + b) >> 1)) & 0xff;
      else if (f === 4) {
        const pa = Math.abs(b - c), pb = Math.abs(a - c), pc = Math.abs(a + b - 2 * c);
        const pr = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
        v = (v + pr) & 0xff;
      }
      cur[x] = v;
    }
    for (let x = 0; x < w; x++) {
      const si = x * ch, di = (y * w + x) * 4;
      out[di] = cur[si]; out[di + 1] = cur[si + 1]; out[di + 2] = cur[si + 2];
      out[di + 3] = (ch === 4) ? cur[si + 3] : 255;
    }
    prev.set(cur);
  }
  return { w, h, data: out };
}

/** 最小 PNG 编码（8bit RGBA，无过滤器），与 decodePNG 配套 */
function encodePNG(f) {
  const zlib = require('zlib');
  const crcTable = encodePNG._t || (encodePNG._t = (() => {
    const t = new Int32Array(256);
    for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1); t[n] = c; }
    return t;
  })());
  const crc32 = (buf) => { let c = ~0; for (let i = 0; i < buf.length; i++) c = crcTable[(c ^ buf[i]) & 0xff] ^ (c >>> 8); return ~c >>> 0; };
  const chunk = (type, data) => {
    const out = Buffer.alloc(12 + data.length);
    out.writeUInt32BE(data.length, 0);
    out.write(type, 4, 'ascii');
    data.copy(out, 8);
    out.writeUInt32BE(crc32(out.slice(4, 8 + data.length)), 8 + data.length);
    return out;
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(f.w, 0); ihdr.writeUInt32BE(f.h, 4);
  ihdr[8] = 8; ihdr[9] = 6;   // 8bit RGBA
  const stride = f.w * 4;
  const raw = Buffer.alloc((stride + 1) * f.h);
  for (let y = 0; y < f.h; y++) {
    raw[y * (stride + 1)] = 0;
    Buffer.from(f.data.buffer, f.data.byteOffset + y * stride, stride).copy(raw, y * (stride + 1) + 1);
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw)),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

function scaleFrame(f, tw, th) {
  if (!f || (f.w === tw && f.h === th)) return f;
  const out = new Uint8Array(tw * th * 4);
  const sxr = f.w / tw, syr = f.h / th;
  for (let y = 0; y < th; y++) for (let x = 0; x < tw; x++) {
    const sx = Math.min(f.w - 1, Math.floor(x * sxr)), sy = Math.min(f.h - 1, Math.floor(y * syr));
    const si = (sy * f.w + sx) * 4, oi = (y * tw + x) * 4;
    out[oi] = f.data[si]; out[oi + 1] = f.data[si + 1]; out[oi + 2] = f.data[si + 2]; out[oi + 3] = f.data[si + 3];
  }
  return { w: tw, h: th, data: out };
}

// ---- 颜色解析（BBGGRR，与 android_cap.py 一致）----
function toInt(c) { if (typeof c === 'number') return c & 0xFFFFFF; let s = String(c).trim(); if (s.toLowerCase().startsWith('0x')) s = s.slice(2); const v = parseInt(s, 16); return isNaN(v) ? 0 : (v & 0xFFFFFF); }
function specRGB(c) { const v = toInt(c); return [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF]; }
function rgbSpec(r, g, b) { return ((b & 0xFF) << 16) | ((g & 0xFF) << 8) | (r & 0xFF); }
function parseOne(spec) {
  spec = String(spec).trim();
  let base, dev;
  if (spec.includes('-')) { const a = spec.split('-'); base = a[0]; dev = a[1] || '000000'; }
  else { base = spec; dev = '000000'; }
  const [r, g, b] = specRGB(base); const [dr, dg, db] = specRGB(dev);
  return [r, g, b, dr, dg, db];
}
function parseMulti(spec) { return String(spec).split('|').filter(x => x.trim() !== '').map(parseOne); }
function simTol(sim) { let s = parseFloat(sim); if (isNaN(s)) s = 0.9; s = Math.max(0, Math.min(1, s)); return Math.round((1 - s) * 255); }
function parseOffset(offset) {
  const out = [];
  for (const part of String(offset).split(',')) {
    const p = part.trim(); if (!p) continue;
    const a = p.split('|'); if (a.length < 3) continue;
    const dx = parseInt(a[0], 10), dy = parseInt(a[1], 10);
    if (isNaN(dx) || isNaN(dy)) continue;
    out.push([dx, dy, parseMulti(a.slice(2).join('|'))]);
  }
  return out;
}

function pxAt(f, x, y) { const i = (y * f.w + x) * 4; return [f.data[i], f.data[i + 1], f.data[i + 2]]; }
function matchesAny(f, x, y, specs, tol) {
  if (x < 0 || y < 0 || x >= f.w || y >= f.h) return false;
  const [r, g, b] = pxAt(f, x, y);
  for (const [sr, sg, sb, dr, dg, db] of specs)
    if (Math.abs(r - sr) <= Math.max(dr, tol) && Math.abs(g - sg) <= Math.max(dg, tol) && Math.abs(b - sb) <= Math.max(db, tol)) return true;
  return false;
}
function pickDir(pts, dirn) {
  if (!pts.length) return null;
  const d = dirn | 0;
  if (d === 1) { const cx = CFG.ios.w / 2, cy = CFG.ios.h / 2; let best = pts[0], bd = Infinity; for (const p of pts) { const dist = (p.x - cx) ** 2 + (p.y - cy) ** 2; if (dist < bd) { bd = dist; best = p; } } return best; }
  if (d === 2) return pts.slice().sort((a, b) => (b.y - a.y) || (b.x - a.x))[0];
  if (d === 3) return pts.slice().sort((a, b) => (b.y - a.y) || (a.x - b.x))[0];
  if (d === 4) return pts.slice().sort((a, b) => (a.y - b.y) || (b.x - a.x))[0];
  return pts[0];
}
function regionOf(f, x1, y1, x2, y2) {
  if (x1 === 0 && y1 === 0 && x2 === 0 && y2 === 0) return [0, 0, f.w, f.h];
  const X1 = Math.max(0, Math.min(x1 | 0, f.w - 1)), Y1 = Math.max(0, Math.min(y1 | 0, f.h - 1));
  return [X1, Y1, Math.max(X1 + 1, Math.min(x2 | 0, f.w)), Math.max(Y1 + 1, Math.min(y2 | 0, f.h))];
}

function iosKeepCapture() {
  if (iosFrame) return true;
  const tmp = path.join(os.tmpdir(), `matisu_ios_${process.pid}_${Date.now()}.png`);
  if (!iosSock('screencap', tmp)) return false;
  if (!fs.existsSync(tmp)) return false;
  const buf = fs.readFileSync(tmp);
  try { fs.unlinkSync(tmp); } catch (_) {}
  const f = decodePNG(buf);
  if (!f) return false;
  // 缩放目标用 devinfo 的真实逻辑尺寸（显示缩放机 320x568 ≠ CFG 静态配置 375x667）
  const lw = iosInfo().width || CFG.ios.w, lh = iosInfo().height || CFG.ios.h;
  iosFrame = scaleFrame(f, lw, lh);
  return !!iosFrame;
}
function iosReleaseCapture() { iosFrame = null; return true; }

function iosFindColor(x1, y1, x2, y2, color, dir, sim) {
  if (!iosFrame && !iosKeepCapture()) return [-1, -1, -1];
  const f = iosFrame; const [X1, Y1, X2, Y2] = regionOf(f, x1, y1, x2, y2);
  const tol = simTol(sim || 0.9); const specs = parseMulti(color); const pts = [];
  for (let y = Y1; y < Y2; y++) for (let x = X1; x < X2; x++)
    if (matchesAny(f, x, y, specs, tol)) pts.push({ x, y, ret: 1 });
  if (!pts.length) return [-1, -1, -1];
  const p = pickDir(pts, dir | 0);
  return [p.ret, p.x, p.y];
}
function iosFindMultiColor(x1, y1, x2, y2, first, offset, dir, sim) {
  if (!iosFrame && !iosKeepCapture()) return [-1, -1];
  const f = iosFrame; const [X1, Y1, X2, Y2] = regionOf(f, x1, y1, x2, y2);
  const tol = simTol(sim || 0.9); const fspecs = parseMulti(first); const offs = parseOffset(offset || '');
  const pts = [];
  for (let y = Y1; y < Y2; y++) for (let x = X1; x < X2; x++) {
    if (!matchesAny(f, x, y, fspecs, tol)) continue;
    let ok = true;
    for (const [dx, dy, sp] of offs) if (!matchesAny(f, x + dx, y + dy, sp, tol)) { ok = false; break; }
    if (ok) pts.push({ x, y });
  }
  if (!pts.length) return [-1, -1];
  const p = pickDir(pts, dir | 0);
  return [p.x, p.y];
}
function iosFindMultiColorAll(x1, y1, x2, y2, first, offset, dir, sim) {
  if (!iosFrame && !iosKeepCapture()) return [];
  const f = iosFrame; const [X1, Y1, X2, Y2] = regionOf(f, x1, y1, x2, y2);
  const tol = simTol(sim || 0.9); const fspecs = parseMulti(first); const offs = parseOffset(offset || '');
  const pts = [];
  for (let y = Y1; y < Y2; y++) for (let x = X1; x < X2; x++) {
    if (!matchesAny(f, x, y, fspecs, tol)) continue;
    let ok = true;
    for (const [dx, dy, sp] of offs) if (!matchesAny(f, x + dx, y + dy, sp, tol)) { ok = false; break; }
    if (ok) pts.push({ x, y });
  }
  return pts;
}
function iosCmpColor(x, y, color, sim) {
  if (!iosFrame && !iosKeepCapture()) return 0;
  const f = iosFrame; const X = x | 0, Y = y | 0;
  if (X < 0 || Y < 0 || X >= f.w || Y >= f.h) return 0;
  return matchesAny(f, X, Y, parseMulti(color), simTol(sim || 0.9)) ? 1 : 0;
}
function iosCmpColorEx(multicolor, sim) {
  if (!iosFrame && !iosKeepCapture()) return 0;
  const f = iosFrame; const tol = simTol(sim || 0.9);
  const pts = String(multicolor).split(',').filter(p => p.trim());
  if (!pts.length) return 0;
  for (const pt of pts) {
    const a = pt.split('|'); if (a.length < 3) return 0;
    const x = parseInt(a[0], 10), y = parseInt(a[1], 10);
    if (isNaN(x) || isNaN(y) || x < 0 || y < 0 || x >= f.w || y >= f.h) return 0;
    if (!matchesAny(f, x, y, parseMulti(a.slice(2).join('|')), tol)) return 0;
  }
  return 1;
}
function iosGetColorNum(x1, y1, x2, y2, color, sim) {
  if (!iosFrame && !iosKeepCapture()) return 0;
  const f = iosFrame; const [X1, Y1, X2, Y2] = regionOf(f, x1, y1, x2, y2);
  const tol = simTol(sim || 0.9); const specs = parseMulti(color); let n = 0;
  for (let y = Y1; y < Y2; y++) for (let x = X1; x < X2; x++) if (matchesAny(f, x, y, specs, tol)) n++;
  return n;
}
function iosGetPixelColor(x, y, type) {
  if (!iosFrame && !iosKeepCapture()) return (type | 0) === 1 ? 0 : '000000';
  const f = iosFrame; const X = x | 0, Y = y | 0;
  if (X < 0 || Y < 0 || X >= f.w || Y >= f.h) return (type | 0) === 1 ? 0 : '000000';
  const i = (Y * f.w + X) * 4; const c = rgbSpec(f.data[i], f.data[i + 1], f.data[i + 2]);
  return (type | 0) === 1 ? c : ('000000' + c.toString(16)).slice(-6).toUpperCase();
}
function iosGetScreenPixel(x1, y1, x2, y2) {
  if (!iosFrame && !iosKeepCapture()) return [-1, -1, []];
  const f = iosFrame; const [X1, Y1, X2, Y2] = regionOf(f, x1, y1, x2, y2);
  const arr = [];
  for (let y = Y1; y < Y2; y++) for (let x = X1; x < X2; x++) { const i = (y * f.w + x) * 4; arr.push(rgbSpec(f.data[i], f.data[i + 1], f.data[i + 2])); }
  return [X2 - X1, Y2 - Y1, arr];
}
function iosIsDisplayDead() { if (!iosFrame && !iosKeepCapture()) return true; return !iosFrame; }
function iosSnapShot(p, x1, y1, x2, y2) {
  const tmp = path.join(os.tmpdir(), `matisu_ios_snap_${process.pid}_${Date.now()}.png`);
  if (!iosSock('screencap', tmp)) return null;
  try {
    let f = decodePNG(fs.readFileSync(tmp));
    fs.unlinkSync(tmp);
    if (!f) return null;
    if (x1 !== undefined) {
      // 带区域：先缩放到逻辑点空间（与 iosFrame 同基准），再裁剪
      const lw = iosInfo().width || CFG.ios.w, lh = iosInfo().height || CFG.ios.h;
      f = scaleFrame(f, lw, lh);
      const [X1, Y1, X2, Y2] = regionOf(f, x1, y1, x2, y2);
      const cw = X2 - X1, ch = Y2 - Y1;
      const out = new Uint8Array(cw * ch * 4);
      for (let y = 0; y < ch; y++) {
        const si = ((Y1 + y) * f.w + X1) * 4;
        out.set(f.data.subarray(si, si + cw * 4), y * cw * 4);
      }
      f = { w: cw, h: ch, data: out };
    }
    fs.writeFileSync(p, encodePNG(f));
    return p;
  } catch (e) { warn('snapShot', e.message); return null; }
}

// ---- iOS 节点过滤（字段名与 android_cap.py pub() 同构）----
const IOS_STR_KEYS = { id: 'id', text: 'text', desc: 'desc', className: 'className', packageName: 'packageName' };
const IOS_BOOL_KEYS = ['visibleToUser', 'selected', 'clickable', 'longClickable', 'enabled', 'focusable', 'focused', 'checkable', 'checked', 'password', 'scrollable'];
const IOS_INT_KEYS = { drawingOrder: 'drawingOrder', depth: 'depth', index: 'index' };
function iosNodeMatch(n, preds) {
  for (const p of (preds || [])) {
    const k = p.k, v = p.v, mode = p.m || 'eq';
    if (IOS_STR_KEYS[k]) {
      const s = String(n[IOS_STR_KEYS[k]] || ''); const vv = String(v == null ? '' : v);
      if (mode === 'contains') { if (!s.includes(vv)) return false; }
      else if (mode === 'startsWith') { if (!s.startsWith(vv)) return false; }
      else if (mode === 'endsWith') { if (!s.endsWith(vv)) return false; }
      else if (mode === 'matches') { try { if (!new RegExp(vv).test(s)) return false; } catch (_) { return false; } }
      else { if (s !== vv) return false; }
    } else if (k === 'bounds') { const [l, t, r, b] = v.map(Number); if (!(n.left === l && n.top === t && n.right === r && n.bottom === b)) return false; }
    else if (k === 'boundsInside') { const [l, t, r, b] = v.map(Number); if (!(n.left >= l && n.top >= t && n.right <= r && n.bottom <= b)) return false; }
    else if (IOS_INT_KEYS[k]) { if (Number(n[IOS_INT_KEYS[k]] || 0) !== Number(v)) return false; }
    else if (IOS_BOOL_KEYS.includes(k)) { if (Boolean(n[k]) !== Boolean(v)) return false; }
  }
  return true;
}
function iosNodes() {
  const now = Date.now();
  if (now - iosNodesCache.ts < 500 && iosNodesCache.list.length) return iosNodesCache.list;
  const out = iosSock('uinode');
  if (!out) return [];
  try { const list = JSON.parse(out.toString('utf8')); iosNodesCache = { ts: now, list }; return list; }
  catch (e) { warn('ios', `uinode 解析失败: ${e.message}`); return []; }
}
function iosNodeQuery(preds, mode, index, indexes) {
  const list = iosNodes();
  if (!list.length) return (mode === 'one' || mode === 'once') ? null : [];
  const fix = (n) => { if (!n) return null; n.left = ox(n.left); n.right = ox(n.right); n.top = oy(n.top); n.bottom = oy(n.bottom); n.cx = ox(n.cx); n.cy = oy(n.cy); return n; };
  if (mode === 'index') { const want = indexes || []; return want.map(i => (i >= 0 && i < list.length) ? fix(list[i]) : null).filter(Boolean); }
  const matched = list.filter(n => iosNodeMatch(n, preds || []));
  if (mode === 'one') return matched.length ? fix(matched[0]) : null;
  if (mode === 'once') { const i = index | 0; return (i >= 0 && i < matched.length) ? fix(matched[i]) : null; }
  return matched.map(fix);
}

// ============================================================ 设备信息

function getDisplaySize() { const [w, h] = realSize(); return [w, h]; }

function getDisplayDpi() {
  if (!isAndroid()) return iosInfo().dpi | 0;
  const s = sh('wm density', 8000) || '';
  const m = s.match(/Override density:\s*(\d+)/) || s.match(/Physical density:\s*(\d+)/);
  return m ? parseInt(m[1], 10) : 0;
}

function getDisplayRotate() {
  if (!isAndroid()) return iosInfo().rotate | 0;
  let s = sh('dumpsys window displays', 10000) || '';
  let m = s.match(/rot=(\d)/) || s.match(/mCurrentRotation=(?:ROTATION_)?(\d)/);
  if (m) return parseInt(m[1], 10);
  s = (sh('settings get system user_rotation', 6000) || '').trim();
  const n = parseInt(s, 10);
  return isNaN(n) ? 0 : n;
}

function getDisplayInfo() {
  const [w, h] = realSize();
  return JSON.stringify({ width: w, height: h, dpi: getDisplayDpi(), rotate: getDisplayRotate() });
}

/** getCpuArch -> 0=x86 1=arm 2=arm64 3=x86_64 */
function getCpuArch() {
  const abi = (isAndroid() ? prop('ro.product.cpu.abi') : (iosInfo().cpuAbi || 'arm64')).toLowerCase();
  if (abi.includes('arm64')) return 2;
  if (abi.includes('x86_64')) return 3;
  if (abi.includes('x86')) return 0;
  if (abi.includes('arm')) return 1;
  return 1;
}

function getSdPath() { return isAndroid() ? '/sdcard' : ''; }
function getModel() { return isAndroid() ? prop('ro.product.model') : (iosInfo().model || iosInfo().name || ''); }
function getManufacturer() { return isAndroid() ? prop('ro.product.manufacturer') : 'Apple'; }
function getBrand() { return isAndroid() ? prop('ro.product.brand') : 'Apple'; }
function getProduct() { return isAndroid() ? prop('ro.product.name') : (iosInfo().modelName || ''); }
function getDevice() { return isAndroid() ? prop('ro.product.device') : (iosInfo().name || ''); }
function getBoard() { return isAndroid() ? prop('ro.product.board') : (iosInfo().model || ''); }
function getHardware() { return isAndroid() ? prop('ro.hardware') : (iosInfo().model || ''); }
function getBootLoader() { return isAndroid() ? prop('ro.bootloader') : ''; }
function getId() { return isAndroid() ? prop('ro.build.id') : (iosInfo().systemVersion || ''); }
function getFingerprint() {
  if (isAndroid()) return prop('ro.build.fingerprint');
  const i = iosInfo();
  return i.model ? `Apple/${i.model}/${i.systemName}${i.systemVersion}` : '';
}
function getCpuAbi() { return isAndroid() ? prop('ro.product.cpu.abi') : (iosInfo().cpuAbi || 'arm64'); }
function getCpuAbi2() { return isAndroid() ? prop('ro.product.cpu.abi2') : ''; }
function getSdkVersion() {
  if (!isAndroid()) return iosInfo().sdk | 0;      // iOS 返回系统主版本号
  const v = parseInt(prop('ro.build.version.sdk'), 10);
  return isNaN(v) ? 0 : v;
}
function getOsVersionName() { return isAndroid() ? prop('ro.build.version.release') : (iosInfo().systemVersion || ''); }

function getDeviceId() {
  if (!isAndroid()) return iosInfo().idfv || '';
  const v = (sh('settings get secure android_id', 8000) || '').trim();
  return (v && v !== 'null') ? v : '';
}

function getWifiMac() {
  if (!isAndroid()) return '';   // iOS 自 7 起系统禁止读取真实 MAC
  let v = (sh('cat /sys/class/net/wlan0/address', 6000) || '').trim();
  if (!v) v = ((sh('ip link show wlan0', 6000) || '').match(/link\/ether ([0-9a-f:]+)/i) || [, ''])[1];
  return v || '';
}

function getBatteryLevel() {
  if (!isAndroid()) { const b = iosInfo().battery; return (b === undefined || b === null) ? -1 : (b | 0); }
  const s = sh('dumpsys battery', 8000) || '';
  const m = s.match(/level:\s*(\d+)/);
  return m ? parseInt(m[1], 10) : -1;
}

function getPackageName() { return frontAppName(); }
function getSubscriberId() { warn('getSubscriberId', 'adb 无权读取 IMSI，返回空'); return ''; }
function getSimSerialNumber() { warn('getSimSerialNumber', 'adb 无权读取 ICCID，返回空'); return ''; }

// ============================================================ 应用管理

function runApp(pkg, component, bySuper) {
  if (!isAndroid()) { warn('runApp', 'iOS 待设备侧接入'); return false; }
  if (component) {
    const cmd = `am start -n ${pkg}/${component}`;
    return (bySuper && hasRoot()) ? suSh(cmd) !== null : adbRun(['shell', cmd]);
  }
  return adbRun(['shell', 'monkey', '-p', pkg, '-c', 'android.intent.category.LAUNCHER', '1']);
}

function stopApp(pkg) {
  if (!isAndroid()) { warn('stopApp', 'iOS 待设备侧接入'); return false; }
  return adbRun(['shell', 'am', 'force-stop', pkg]);
}

function appIsRunning(pkg) {
  if (!isAndroid()) return false;
  const out = sh(`pidof ${pkg}`, 8000);
  return !!(out && out.trim().length > 0);
}

function frontAppName() {
  if (!isAndroid()) {
    // 优先设备 frontapp 命令（SpringBoardServices 私有 API）；
    // 兜底取节点树里前台 App 的进程名（由 AXNodeDump 通过 AXUIElementGetPid + proc_name 填充）
    const r = iosSock('frontapp');
    if (r) {
      const s = r.toString('utf8').trim();
      if (s) return s;
    }
    const l = iosNodes();
    for (const n of l) if (n.packageName) return n.packageName;
    return '';
  }
  const s = sh('dumpsys window', 12000) || '';
  const m = s.match(/mCurrentFocus=\S+\s+\S+\s+([\w.]+)\//) || s.match(/mFocusedApp=\S+\s+\S+\s+([\w.]+)\//);
  if (m) return m[1];
  const a = (sh('dumpsys activity activities', 12000) || '').match(/mResumedActivity[^\n]*?\s([\w.]+)\//);
  return a ? a[1] : '';
}

function appIsFront(pkg) { return frontAppName() === pkg; }

function getCurrentActivity() {
  if (!isAndroid()) return '';
  const s = sh('dumpsys window', 12000) || '';
  const m = s.match(/mCurrentFocus=\S+\s+\S+\s+([\w.]+\/[\w.$]+)/);
  return m ? m[1] : '';
}

function getInstalledApk() {
  if (!isAndroid()) return [];
  const s = sh('pm list packages', 20000) || '';
  return s.split(/\r?\n/).map(l => l.replace(/^package:/, '').trim()).filter(Boolean);
}

function installApk(p) {
  if (!isAndroid()) return false;
  return adbRun(['install', '-r', p], 180000);
}

function readPasteboard() {
  if (!isAndroid()) return '';
  const r = sh('cmd clipboard get-text', 8000);
  if (r && !/Unknown command|Exception/i.test(r)) return r.replace(/\r?\n$/, '');
  warn('readPasteboard', '设备不支持 cmd clipboard（需 API 29+ 或设备侧助手），返回空');
  return '';
}

function writePasteboard(str) {
  if (!isAndroid()) return false;
  const r = sh(`cmd clipboard set-text '${String(str).replace(/'/g, "'\\''")}'`, 8000);
  if (r !== null && !/Unknown command|Exception/i.test(r)) return true;
  warn('writePasteboard', '设备不支持 cmd clipboard（需 API 29+ 或设备侧助手）');
  return false;
}

function phoneCall(num) { return adbRun(['shell', 'am', 'start', '-a', 'android.intent.action.CALL', '-d', `tel:${num}`]); }
function runIntent(action, uri) {
  const args = ['shell', 'am', 'start', '-a', action];
  if (uri) args.push('-d', uri);
  return adbRun(args);
}

// ============================================================ 系统控制

/** exec(cmd,[isRet])：以最高权限执行；isRet 默认 true。 */
function exec(cmd, isRet) {
  if (!isAndroid()) { warn('exec', 'iOS 待设备侧接入'); return ''; }
  const want = (isRet === undefined || isRet === null) ? true : !!isRet;
  const out = hasRoot() ? suSh(cmd, 60000) : sh(cmd, 60000);
  return want ? (out === null ? '' : out) : '';
}

function vibrate(during) {
  const ms = Math.max(1, (during == null ? 100 : during) | 0);
  if (!isAndroid()) return false;
  // cmd vibrator（新）/ 直接写 sysfs（root 兜底）
  let r = sh(`cmd vibrator vibrate ${ms}`, 8000);
  if (r !== null && !/Unknown|Exception/i.test(r)) return true;
  if (hasRoot()) return suSh(`echo ${ms} > /sys/class/timed_output/vibrator/enable`) !== null;
  warn('vibrate', '设备不支持 cmd vibrator 且无 root');
  return false;
}

function lockScreen() {
  // 懒人精灵语义：保持屏幕长亮
  if (!isAndroid()) return false;
  return adbRun(['shell', 'svc', 'power', 'stayon', 'true']);
}
function unLockScreen() {
  if (!isAndroid()) return false;
  return adbRun(['shell', 'svc', 'power', 'stayon', 'false']);
}
function setBTEnable(on) { return adbRun(['shell', 'svc', 'bluetooth', on ? 'enable' : 'disable']); }
function setWifiEnable(on) { return adbRun(['shell', 'svc', 'wifi', on ? 'enable' : 'disable']); }
function setAirplaneMode(on) {
  adbRun(['shell', 'settings', 'put', 'global', 'airplane_mode_on', on ? 1 : 0]);
  return adbRun(['shell', 'am', 'broadcast', '-a', 'android.intent.action.AIRPLANE_MODE', '--ez', 'state', on ? 'true' : 'false']);
}

/** getRunEnvType -> 0=root/激活  1=无障碍（iOS TrollStore 应用为无沙箱 root 等价，返回 0） */
function getRunEnvType() { return isAndroid() ? (hasRoot() ? 0 : 1) : 0; }

// ============================================================ 找图（模板匹配，双端统一 JS 实现）
// iOS 用 iosFrame，Android 用 pyCap getscreenpixel；模板为 PNG 文件（支持 RGBA，findPicEx 跳过透明像素）
const tplCache = new Map();

function loadTemplate(pic) {
  const key = String(pic);
  if (tplCache.has(key)) return tplCache.get(key);
  if (!fs.existsSync(key)) { warn('findPic', '模板不存在: ' + key); return null; }
  const f = decodePNG(fs.readFileSync(key));
  if (!f) return null;
  const n = f.w * f.h;
  const pix = new Int32Array(n), mask = new Uint8Array(n);
  for (let i = 0; i < n; i++) {
    const si = i * 4;
    pix[i] = rgbSpec(f.data[si], f.data[si + 1], f.data[si + 2]);
    mask[i] = f.data[si + 3] >= 128 ? 1 : 0;
  }
  const t = { w: f.w, h: f.h, pix, mask };
  tplCache.set(key, t);
  return t;
}

/** 整屏像素 {w,h,arr}（BBGGRR int 行优先） */
function screenPixels() {
  if (!isAndroid()) {
    if (!iosFrame && !iosKeepCapture()) return null;
    const f = iosFrame, n = f.w * f.h, arr = new Int32Array(n);
    for (let i = 0; i < n; i++) { const si = i * 4; arr[i] = rgbSpec(f.data[si], f.data[si + 1], f.data[si + 2]); }
    return { w: f.w, h: f.h, arr };
  }
  const r = pyCap('getscreenpixel', { reg: [0, 0, 0, 0] });
  if (!r || r.w === undefined) return null;
  return { w: r.w, h: r.h, arr: r.arr || [] };
}

/** 单点相似度（1 - meanAbsDiff/255）；useMask 时跳过模板透明像素 */
function tplScore(scr, tpl, px, py, useMask) {
  const tw = tpl.w, th = tpl.h;
  let diff = 0, cnt = 0;
  for (let ty = 0; ty < th; ty++) {
    const srow = (py + ty) * scr.w + px, trow = ty * tw;
    for (let tx = 0; tx < tw; tx++) {
      const ti = trow + tx;
      if (useMask && !tpl.mask[ti]) continue;
      const a = scr.arr[srow + tx] >>> 0, b = tpl.pix[ti] >>> 0;
      diff += Math.abs((a & 0xFF) - (b & 0xFF)) + Math.abs(((a >> 8) & 0xFF) - ((b >> 8) & 0xFF)) + Math.abs(((a >> 16) & 0xFF) - ((b >> 16) & 0xFF));
      cnt += 3;
    }
  }
  if (!cnt) return 0;
  return 1 - (diff / cnt) / 255;
}

/** 粗扫（步长 step）+ 命中点精修，返回 {x,y,s} 或 null */
function matchTemplate(scr, tpl, X1, Y1, X2, Y2, sim, useMask) {
  const tw = tpl.w, th = tpl.h;
  const x2 = Math.min(X2 - tw, scr.w - tw), y2 = Math.min(Y2 - th, scr.h - th);
  if (x2 < X1 || y2 < Y1) return null;
  const step = Math.max(2, Math.min(tw, th) >> 3);
  const cands = [];
  for (let y = Y1; y <= y2; y += step) for (let x = X1; x <= x2; x += step) {
    // 稀疏 9 点预筛
    let pre = 0;
    for (let k = 0; k < 9; k++) {
      const tx = (k % 3) * (tw >> 2) + (tw >> 3), ty = ((k / 3) | 0) * (th >> 2) + (th >> 3);
      const ti = ty * tw + tx;
      if (useMask && !tpl.mask[ti]) continue;
      const a = scr.arr[(y + ty) * scr.w + x + tx] >>> 0, b = tpl.pix[ti] >>> 0;
      pre += Math.abs((a & 0xFF) - (b & 0xFF)) + Math.abs(((a >> 8) & 0xFF) - ((b >> 8) & 0xFF)) + Math.abs(((a >> 16) & 0xFF) - ((b >> 16) & 0xFF));
    }
    if (1 - (pre / 27) / 255 >= sim - 0.15) cands.push([x, y]);
  }
  let best = null;
  for (const [cx, cy] of cands) {
    const x1r = Math.max(X1, cx - step), y1r = Math.max(Y1, cy - step);
    const x2r = Math.min(x2, cx + step), y2r = Math.min(y2, cy + step);
    for (let y = y1r; y <= y2r; y++) for (let x = x1r; x <= x2r; x++) {
      const s = tplScore(scr, tpl, x, y, useMask);
      if (s >= sim && (!best || s > best.s)) best = { x, y, s };
    }
  }
  return best;
}

/** 收集所有 >= sim 的命中（按模板半径做非极大值抑制） */
function matchTemplateAll(scr, tpl, X1, Y1, X2, Y2, sim, useMask) {
  const tw = tpl.w, th = tpl.h;
  const x2 = Math.min(X2 - tw, scr.w - tw), y2 = Math.min(Y2 - th, scr.h - th);
  if (x2 < X1 || y2 < Y1) return [];
  const step = Math.max(2, Math.min(tw, th) >> 3);
  const hits = [];
  for (let y = Y1; y <= y2; y += step) for (let x = X1; x <= x2; x += step) {
    const s = tplScore(scr, tpl, x, y, useMask);
    if (s >= sim) hits.push({ x, y, s });
  }
  hits.sort((a, b) => b.s - a.s);
  const out = [], rad = Math.max(tw, th) >> 1;
  for (const h of hits) {
    if (out.every(o => Math.abs(o.x - h.x) > rad || Math.abs(o.y - h.y) > rad)) out.push(h);
  }
  return out;
}

/**
 * findPic(x1,y1,x2,y2,pic,delta_color,dir,sim) -> [ret,x,y]
 * delta_color 暂作保留参数（偏色容差由 sim 统一控制）。
 */
function findPic(x1, y1, x2, y2, pic, delta, dir, sim) {
  const tpl = loadTemplate(pic); if (!tpl) return [-1, -1, -1];
  const scr = screenPixels(); if (!scr) return [-1, -1, -1];
  const reg = inReg(x1, y1, x2, y2);
  const [X1, Y1, X2, Y2] = regionOf(scr, reg[0], reg[1], reg[2], reg[3]);
  const hit = matchTemplate(scr, tpl, X1, Y1, X2, Y2, sim == null ? 0.9 : sim, false);
  if (!hit) return [-1, -1, -1];
  return [1, ox(hit.x), oy(hit.y)];
}

/** findPicEx：透明找图（跳过模板透明像素），返回同 findPic */
function findPicEx(x1, y1, x2, y2, pic, sim) {
  const tpl = loadTemplate(pic); if (!tpl) return [-1, -1, -1];
  const scr = screenPixels(); if (!scr) return [-1, -1, -1];
  const reg = inReg(x1, y1, x2, y2);
  const [X1, Y1, X2, Y2] = regionOf(scr, reg[0], reg[1], reg[2], reg[3]);
  const hit = matchTemplate(scr, tpl, X1, Y1, X2, Y2, sim == null ? 0.9 : sim, true);
  if (!hit) return [-1, -1, -1];
  return [1, ox(hit.x), oy(hit.y)];
}

/** findImage：opencv 模板匹配等价（同 findPic 的 NCC-lite） */
function findImage(x1, y1, x2, y2, pic, sim) {
  return findPic(x1, y1, x2, y2, pic, null, 0, sim);
}

/** findPicAllPoint -> [{x,y,sim}...]（相似度降序） */
function findPicAllPoint(x1, y1, x2, y2, pic, sim) {
  const tpl = loadTemplate(pic); if (!tpl) return [];
  const scr = screenPixels(); if (!scr) return [];
  const reg = inReg(x1, y1, x2, y2);
  const [X1, Y1, X2, Y2] = regionOf(scr, reg[0], reg[1], reg[2], reg[3]);
  return matchTemplateAll(scr, tpl, X1, Y1, X2, Y2, sim == null ? 0.9 : sim, false)
    .map(h => ({ x: ox(h.x), y: oy(h.y), sim: Math.round(h.s * 1000) / 1000 }));
}

// ============================================================ 交互（PC 宿主无设备端 UI，落到控制台）

function toast(text, x, y, size) {
  console.log(`[toast] ${text}`);
  return true;
}
function hideToast() { return true; }

module.exports = {
  CFG, sleepSync, hasRoot, realSize, touchDev, isAndroid,
  // 触控
  tap, longTap, swipe, touchDown, touchMove, touchMoveEx, touchUp,
  keyPress, keyDown, keyUp, inputText, setOnTouchListener,
  // 图色
  setScreenScale, keepCapture, releaseCapture, findColor, findMultiColor, findMultiColorAll,
  cmpColor, cmpColorEx, getColorNum, colorDiff, colorToRGB, getPixelColor, getScreenPixel,
  isDisplayDead, snapShot, ocrText, findPic, findPicEx, findImage, findPicAllPoint,
  // 节点
  nodeQuery, nodeXml,
  // 设备信息
  getDisplaySize, getDisplayDpi, getDisplayRotate, getDisplayInfo, getCpuArch, getSdPath,
  getModel, getManufacturer, getBrand, getProduct, getDevice, getBoard, getHardware,
  getBootLoader, getId, getFingerprint, getCpuAbi, getCpuAbi2, getSdkVersion, getOsVersionName,
  getDeviceId, getWifiMac, getBatteryLevel, getPackageName, getSubscriberId, getSimSerialNumber,
  // 应用
  runApp, stopApp, appIsRunning, frontAppName, appIsFront, getCurrentActivity,
  getInstalledApk, installApk, readPasteboard, writePasteboard, phoneCall, runIntent,
  // 系统
  exec, vibrate, lockScreen, unLockScreen, setBTEnable, setWifiEnable, setAirplaneMode, getRunEnvType,
  // 交互
  toast, hideToast,
};
