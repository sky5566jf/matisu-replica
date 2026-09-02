// MatisuAuto PC IDE —— 零依赖 node 后端（抓抓取色 + 脚本运行）
// 用法：node server.js [port]   默认 5586；浏览器开 http://127.0.0.1:5586
// 设备切换：页面内 iOS/Android 按钮（服务端改 bridge.CFG.target）
const http = require('http');
const fs = require('fs');
const path = require('path');

process.env.MATISU_IOS_HOST = process.env.MATISU_IOS_HOST || '192.69.0.38';
process.env.MATISU_IOS_PORT = process.env.MATISU_IOS_PORT || '18182';

const bridge = require(path.join(__dirname, '..', 'device_bridge.js'));
const os = require('os');
const { execFileSync } = require('child_process');

const PY = 'C:/Users/Administrator/.workbuddy/binaries/python/envs/default/Scripts/python.exe';
const IOS_SOCK = path.join(__dirname, '..', 'ios_sock.py');

function iosSock(cmd, timeout = 20000) {
  try {
    return execFileSync(PY, [IOS_SOCK, cmd], {
      timeout,
      env: { ...process.env, MATISU_IOS_HOST: bridge.CFG.ios.host, MATISU_IOS_PORT: String(bridge.CFG.ios.port) },
      maxBuffer: 64 * 1024 * 1024,
    });
  } catch (e) { return null; }
}

// ---- Android 设备端引擎通道（:18183，adb forward）----
const net = require('net');
let adbForwarded = false;
function ensureAdbForward() {
  if (adbForwarded) return;
  try {
    execFileSync(bridge.CFG.android.adb, ['-s', bridge.CFG.android.device, 'forward', 'tcp:18183', 'tcp:18183'], { timeout: 10000 });
    adbForwarded = true;
  } catch (_) {}
}
/** 向 Android 引擎发指令（与 iOS iosSock 同协议：[4B 长度][payload]） */
function androidSock(cmd, timeout = 20000) {
  return new Promise((resolve) => {
    ensureAdbForward();
    const sock = new net.Socket();
    let done = false;
    const finish = (v) => { if (!done) { done = true; try { sock.destroy(); } catch (_) {} resolve(v); } };
    sock.setTimeout(timeout);
    const chunks = [];
    sock.connect(18183, '127.0.0.1', () => sock.write(cmd + '\n'));
    sock.on('data', (d) => chunks.push(d));
    sock.on('end', () => finish(Buffer.concat(chunks).slice(4)));   // 去 4B 长度头
    sock.on('timeout', () => finish(null));
    sock.on('error', () => finish(null));
  });
}
/** 统一引擎通道：当前 target 决定走 iOS 还是 Android */
async function engineSock(cmd, timeout = 20000) {
  if (bridge.CFG.target === 'android') return androidSock(cmd, timeout);
  return iosSock(cmd, timeout);
}

const PORT = parseInt(process.argv[2] || '5586', 10);
let lastScreen = null;   // 最近一次截图（裁剪/找图复用）
const TPL_DIR = path.join(__dirname, 'templates');
if (!fs.existsSync(TPL_DIR)) fs.mkdirSync(TPL_DIR, { recursive: true });

// ---- 多设备管理 ----
const DEVICES_FILE = path.join(__dirname, 'devices.json');
function loadDevices() {
  try { return JSON.parse(fs.readFileSync(DEVICES_FILE, 'utf8')); }
  catch (_) {
    return {
      active: 'iphone38',
      devices: [
        { id: 'iphone38', name: 'iPhone SE2', type: 'ios', host: '192.69.0.38', port: 18182 },
        { id: 'emu18', name: 'Android 模拟器', type: 'android', host: '192.69.0.18', port: 5555 },
      ],
    };
  }
}
function saveDevices(d) { fs.writeFileSync(DEVICES_FILE, JSON.stringify(d, null, 2), 'utf8'); }
function applyDevice(dev) {
  if (!dev) return false;
  bridge.CFG.target = dev.type;
  if (dev.type === 'ios') { bridge.CFG.ios.host = dev.host; bridge.CFG.ios.port = dev.port | 0 || 18182; }
  else { bridge.CFG.android.device = dev.host + ':' + (dev.port | 0 || 5555); adbForwarded = false; }
  return true;
}
// 启动时应用活动设备
{ const d0 = loadDevices(); applyDevice(d0.devices.find((x) => x.id === d0.active) || d0.devices[0]); }

function send(res, code, body, type = 'application/json') {
  res.writeHead(code, { 'Content-Type': type, 'Access-Control-Allow-Origin': '*' });
  res.end(body);
}
function readBody(req) {
  return new Promise((resolve) => {
    let d = '';
    req.on('data', (c) => (d += c));
    req.on('end', () => { try { resolve(JSON.parse(d || '{}')); } catch (_) { resolve({}); } });
  });
}

// 截图（按当前 target）
function captureScreen() {
  if (bridge.CFG.target === 'android') {
    const tmp = path.join(os.tmpdir(), `matisu_ide_${process.pid}_${Date.now()}.png`);
    const r = bridge.snapShot(tmp);
    if (!r || !fs.existsSync(tmp)) return null;
    const buf = fs.readFileSync(tmp);
    try { fs.unlinkSync(tmp); } catch (_) {}
    return buf;
  }
  // iOS：ios_sock.py 需 outfile 参数写文件
  const tmp = path.join(os.tmpdir(), `matisu_ide_${process.pid}_${Date.now()}.png`);
  try {
    execFileSync(PY, [IOS_SOCK, 'screencap', tmp], {
      timeout: 20000,
      env: { ...process.env, MATISU_IOS_HOST: bridge.CFG.ios.host, MATISU_IOS_PORT: String(bridge.CFG.ios.port) },
      maxBuffer: 64 * 1024 * 1024,
    });
    if (!fs.existsSync(tmp)) return null;
    const buf = fs.readFileSync(tmp);
    try { fs.unlinkSync(tmp); } catch (_) {}
    return buf;
  } catch (e) { return null; }
}

// 单点取色（iOS 走 getpixel 指令，Android 走 cap 服务）
function pickPixel(x, y) {
  if (bridge.CFG.target === 'android') {
    const c = bridge.getPixelColor(x, y, 0);
    return c && c !== '000000' ? c : null;
  }
  const out = iosSock(`getpixel ${x | 0} ${y | 0}`);
  if (!out) return null;
  const s = String(out).trim();
  return /^[0-9A-Fa-f]{6}$/.test(s) ? s.toUpperCase() : null;
}

const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  const p = u.pathname;

  if (p === '/') return send(res, 200, fs.readFileSync(path.join(__dirname, 'index.html')), 'text/html; charset=utf-8');
  if (p === '/zhuazhua') return send(res, 200, fs.readFileSync(path.join(__dirname, 'zhuazhua.html')), 'text/html; charset=utf-8');
  if (p === '/nodes') return send(res, 200, fs.readFileSync(path.join(__dirname, 'nodes.html')), 'text/html; charset=utf-8');
  // CodeMirror 6 + LSP 客户端打包产物（esbuild IIFE，全局名 MatisuEditor）
  if (p === '/editor.js') {
    const f = path.join(__dirname, 'editor-build', 'bundle.js');
    if (!fs.existsSync(f)) return send(res, 404, '// bundle 缺失，前端自动回退 textarea');
    return send(res, 200, fs.readFileSync(f), 'application/javascript; charset=utf-8');
  }
  // LSP 可用性 + 工作区参数（前端据此决定是否升级 CodeMirror 编辑器）
  if (p === '/api/lsp') {
    const { pathToFileURL } = require('url');
    const ok = fs.existsSync(LSP_EXE);
    return send(res, 200, JSON.stringify({
      ok,
      rootUri: pathToFileURL(path.join(__dirname, 'scripts') + path.sep).href,
      libraryUri: fs.existsSync(LSP_META) ? pathToFileURL(LSP_META + path.sep).href : null,
    }));
  }

  // ---- API 契约清单（从 core.lua 解析：分节注释 + _stub 函数名 + 表方法）----
  if (p === '/api/apis') {
    try {
      const core = fs.readFileSync(path.join(__dirname, '..', '..', 'common', 'lua-api', 'core.lua'), 'utf8');
      const sections = [];
      let cur = { name: '全局', fns: [] };
      for (const line of core.split('\n')) {
        const sec = line.match(/^--\s*[一二三四五六七八九十]+、(.+)$/);
        if (sec) { if (cur.fns.length) sections.push(cur); cur = { name: sec[1].trim(), fns: [] }; continue; }
        const m = line.match(/_stub\("([^"]+)"\)/);
        if (m) { cur.fns.push(m[1]); continue; }
        const m2 = line.match(/^\s*(?:function\s+)?(?:jsonLib|imeLib|ImageUtil|ui|nodeLib|strutils|cryptLib|console|lfs)\.(\w+)/);
        if (m2) cur.fns.push(line.trim().split('.')[0].replace(/^\W+/, '') + '.' + m2[1]);
      }
      if (cur.fns.length) sections.push(cur);
      return send(res, 200, JSON.stringify(sections));
    } catch (e) { return send(res, 500, JSON.stringify({ error: e.message })); }
  }

  // ---- 脚本管理（iOS/Android 均走设备引擎通道；Android 需 APK v2+ 的 readfile 指令）----
  const LOCAL_SCRIPTS = path.join(__dirname, 'scripts');
  if (!fs.existsSync(LOCAL_SCRIPTS)) fs.mkdirSync(LOCAL_SCRIPTS, { recursive: true });

  if (p === '/api/scripts') {
    if (bridge.CFG.target === 'android') {
      const out0 = await engineSock('list');
      try {
        const all = JSON.parse(String(out0));
        return send(res, 200, JSON.stringify(all.filter((f) => String(f).endsWith('.lua'))));
      } catch (_) { return send(res, 200, '[]'); }
    }
    const out = iosSock('list');
    try {
      const all = JSON.parse(String(out));
      return send(res, 200, JSON.stringify(all.filter((f) => String(f).endsWith('.lua'))));   // 文件管理只列脚本
    } catch (_) { return send(res, 200, '[]'); }
  }

  if (p === '/api/script' && req.method === 'GET') {
    const name = u.searchParams.get('name') || '';
    if (!name || name.includes('..')) return send(res, 400, '{"error":"bad name"}');
    if (bridge.CFG.target === 'android') {
      const outR = await engineSock('readfile ' + name);
      return send(res, 200, JSON.stringify({ code: outR ? String(outR) : '' }));
    }
    // iOS：经 run 指令读设备文件内容
    const rb = Buffer.from(`local f = io.open("/var/mobile/Media/com.matisu.auto/run/脚本/${name}", "r") if f then print(f:read("*a")) f:close() end`, 'utf8').toString('base64');
    const out2 = iosSock('run ' + rb);
    try { const d = JSON.parse(String(out2)); return send(res, 200, JSON.stringify({ code: d.output || '' })); }
    catch (_) { return send(res, 200, '{"code":""}'); }
  }

  if (p === '/api/script' && req.method === 'POST') {
    const b = await readBody(req);
    const name = String(b.name || '');
    if (!name || name.includes('..')) return send(res, 400, '{"error":"bad name"}');
    if (bridge.CFG.target === 'android') {
      const b64n2 = Buffer.from(name, 'utf8').toString('base64');
      const b64c2 = Buffer.from(String(b.code || ''), 'utf8').toString('base64');
      const outU = await engineSock(`upload ${b64n2} ${b64c2}`);
      return send(res, 200, JSON.stringify({ ok: String(outU).trim() === 'OK' }));
    }
    const b64n = Buffer.from(name, 'utf8').toString('base64');
    const b64c = Buffer.from(String(b.code || ''), 'utf8').toString('base64');
    const out3 = iosSock(`upload ${b64n} ${b64c}`);
    return send(res, 200, JSON.stringify({ ok: String(out3).trim() === 'OK' }));
  }

  if (p === '/api/script' && req.method === 'DELETE') {
    const name = u.searchParams.get('name') || '';
    if (!name || name.includes('..')) return send(res, 400, '{"error":"bad name"}');
    if (bridge.CFG.target === 'android') {
      const outD = await engineSock('delete ' + name);
      return send(res, 200, JSON.stringify({ ok: String(outD).trim() === 'OK' }));
    }
    const out4 = iosSock('delete ' + name);
    return send(res, 200, JSON.stringify({ ok: String(out4).trim() === 'OK' }));
  }

  if (p === '/api/runfile' && req.method === 'POST') {
    const b = await readBody(req);
    const out5 = await engineSock('runfile ' + String(b.name || ''), 60000);
    if (!out5) return send(res, 502, '{"ok":false,"error":"runfile 失败"}');
    return send(res, 200, String(out5));
  }

  if (p === '/api/export' && req.method === 'POST') {
    // {name, files[]}：把设备脚本打包成自启动 tipa
    const b = await readBody(req);
    const name = String(b.name || '我的脚本').replace(/[\\/:*?"<>|]/g, '_');
    const files = Array.isArray(b.files) ? b.files : [];
    if (!files.length) return send(res, 400, '{"error":"未选择脚本"}');
    // 1. 拉取脚本内容到临时目录
    const tmpDir = path.join(os.tmpdir(), `matisu_export_${Date.now()}`);
    fs.mkdirSync(tmpDir, { recursive: true });
    for (const f of files) {
      let code = '';
      if (bridge.CFG.target === 'android') {
        const outR2 = await engineSock('readfile ' + f);
        code = outR2 ? String(outR2) : '';
      } else {
        const rb = Buffer.from(`local f = io.open("/var/mobile/Media/com.matisu.auto/run/脚本/${f}", "r") if f then print(f:read("*a")) f:close() end`, 'utf8').toString('base64');
        const out7 = iosSock('run ' + rb);
        try { code = JSON.parse(String(out7)).output || ''; } catch (_) {}
      }
      fs.writeFileSync(path.join(tmpDir, f), code, 'utf8');
    }
    // 2. 调打包工具
    const baseTipa = path.join(__dirname, '..', '..', 'ci_artifacts', 'matisu-auto.tipa');
    const outTipa = path.join(__dirname, '..', '..', 'ci_artifacts', `${name}.tipa`);
    try {
      const out = execFileSync(PY, [path.join(__dirname, '..', 'tools', 'export_tipa.py'), baseTipa, tmpDir, outTipa, '--name', name], { encoding: 'utf8', timeout: 60000 });
      try { fs.rmSync(tmpDir, { recursive: true }); } catch (_) {}
      return send(res, 200, JSON.stringify({ ok: true, path: outTipa, log: out.trim() }));
    } catch (e) {
      return send(res, 500, JSON.stringify({ ok: false, error: String(e.message).slice(0, 300) }));
    }
  }

  if (p === '/api/svc' && req.method === 'POST') {
    // 常驻控制：{action: start|stop|state, code?}
    const b = await readBody(req);
    let out6;
    if (b.action === 'start') out6 = await engineSock('start ' + Buffer.from(String(b.code || ''), 'utf8').toString('base64'));
    else if (b.action === 'stop') out6 = await engineSock('stop');
    else out6 = await engineSock('state');
    if (b.action === 'state') { try { return send(res, 200, String(out6)); } catch (_) { return send(res, 200, '{}'); } }
    return send(res, 200, JSON.stringify({ ok: String(out6).trim() === 'OK' }));
  }

  // ---- 引擎日志流（双端 logtail 协议一致：{off, data}）----
  if (p === '/api/logtail') {
    const off = parseInt(u.searchParams.get('off') || '0', 10);
    const out = await engineSock('logtail ' + (off | 0), 15000);
    const s = out ? String(out).trim() : '';
    if (!s.startsWith('{')) return send(res, 200, JSON.stringify({ off: off | 0, data: '', offline: true }));
    return send(res, 200, s);
  }

  // ---- 节点查看器（Android=nodetree 无障碍节点树；iOS=uinode AX 节点（需 tweak/授权））----
  if (p === '/api/nodetree') {
    const out = await engineSock(bridge.CFG.target === 'android' ? 'nodetree' : 'uinode', 15000);
    const s = out ? String(out).trim() : '';
    if (!s.startsWith('{')) return send(res, 502, JSON.stringify({ count: 0, error: '设备无响应或不支持节点查询' }));
    return send(res, 200, s);
  }

  // ---- 设备 CRUD ----
  if (p === '/api/devices' && req.method === 'GET') {
    const d = loadDevices();
    return send(res, 200, JSON.stringify(d));
  }
  if (p === '/api/devices' && req.method === 'POST') {
    // {op: add|delete|switch, device?/id?}
    const b = await readBody(req);
    const d = loadDevices();
    if (b.op === 'add') {
      const dev = b.device || {};
      if (!dev.id || !dev.host || !dev.type) return send(res, 400, '{"error":"id/host/type 必填"}');
      d.devices = d.devices.filter((x) => x.id !== dev.id);
      d.devices.push(dev);
      saveDevices(d);
      return send(res, 200, JSON.stringify({ ok: true }));
    }
    if (b.op === 'delete') {
      d.devices = d.devices.filter((x) => x.id !== b.id);
      if (d.active === b.id) d.active = d.devices[0] ? d.devices[0].id : '';
      saveDevices(d);
      const cur = d.devices.find((x) => x.id === d.active);
      if (cur) applyDevice(cur);
      return send(res, 200, JSON.stringify({ ok: true }));
    }
    if (b.op === 'switch') {
      const dev = d.devices.find((x) => x.id === b.id);
      if (!dev) return send(res, 404, '{"error":"设备不存在"}');
      d.active = b.id;
      saveDevices(d);
      applyDevice(dev);
      return send(res, 200, JSON.stringify({ ok: true, target: dev.type }));
    }
    return send(res, 400, '{"error":"op 必填"}');
  }

  if (p === '/api/target' && req.method === 'POST') {
    const b = await readBody(req);
    if (b.target === 'ios' || b.target === 'android') bridge.CFG.target = b.target;
    return send(res, 200, JSON.stringify({ target: bridge.CFG.target }));
  }

  if (p === '/api/devinfo') {
    const d = bridge.CFG.target === 'android'
      ? { model: bridge.getModel(), width: bridge.CFG.android.w, height: bridge.CFG.android.h, scale: 1 }
      : JSON.parse(String(iosSock('devinfo') || '{}'));
    return send(res, 200, JSON.stringify({ target: bridge.CFG.target, ...d }));
  }

  if (p === '/api/screen') {
    const buf = captureScreen();
    if (!buf) return send(res, 502, JSON.stringify({ error: 'screencap failed' }));
    lastScreen = buf;   // 裁剪/找图复用
    return send(res, 200, buf, 'image/png');
  }

  if (p === '/api/pixel') {
    const c = pickPixel(parseInt(u.searchParams.get('x'), 10), parseInt(u.searchParams.get('y'), 10));
    return send(res, 200, JSON.stringify({ color: c }));
  }

  if (p === '/api/findcolor') {
    const q = u.searchParams;
    const r = bridge.findColor(
      parseInt(q.get('x1') || '0', 10), parseInt(q.get('y1') || '0', 10),
      parseInt(q.get('x2') || '0', 10), parseInt(q.get('y2') || '0', 10),
      q.get('color'), parseInt(q.get('dir') || '0', 10), parseFloat(q.get('sim') || '0.9'));
    return send(res, 200, JSON.stringify({ ret: r[0], x: r[1], y: r[2] }));
  }

  if (p === '/api/cmpcolorex' && req.method === 'POST') {
    const b = await readBody(req);
    const r = bridge.cmpColorEx(b.multi || '', b.sim == null ? 0.9 : b.sim);
    return send(res, 200, JSON.stringify({ ret: r }));
  }

  // ---- 抓抓三件套：裁剪模板 / 模板列表 / 图片查找 ----
  if (p === '/api/crop' && req.method === 'POST') {
    // {x1,y1,x2,y2(逻辑坐标),name}：区域截图存模板——snapShot 内部完成
    // 物理帧→devinfo 逻辑尺寸缩放→裁剪，产物与 findPic 搜索帧同尺寸基准。
    const b = await readBody(req);
    const name = String(b.name || ('tpl_' + Date.now() + '.png')).replace(/[^\w.一-龥-]/g, '_');
    const out = path.join(TPL_DIR, name);
    const r = bridge.snapShot(out, b.x1 | 0, b.y1 | 0, b.x2 | 0, b.y2 | 0);
    return send(res, 200, JSON.stringify({ ok: !!r, name }));
  }

  if (p === '/api/templates') {
    const list = fs.readdirSync(TPL_DIR).filter((f) => f.endsWith('.png'));
    return send(res, 200, JSON.stringify(list));
  }

  if (p.startsWith('/templates/')) {
    const f = path.join(TPL_DIR, p.slice('/templates/'.length));
    if (!f.startsWith(TPL_DIR) || !fs.existsSync(f)) return send(res, 404, '{}');
    return send(res, 200, fs.readFileSync(f), 'image/png');
  }

  if (p === '/api/findpic' && req.method === 'POST') {
    // {name, x1,y1,x2,y2, sim}：设备全帧找图（模板为物理像素，帧经 devinfo 缩放——坐标返回逻辑点）
    const b = await readBody(req);
    const tpl = path.join(TPL_DIR, String(b.name || ''));
    if (!fs.existsSync(tpl)) return send(res, 404, '{"error":"模板不存在"}');
    const r = bridge.findPic(b.x1 | 0, b.y1 | 0, b.x2 | 0, b.y2 | 0, tpl, null, 0, b.sim == null ? 0.9 : b.sim);
    return send(res, 200, JSON.stringify({ ret: r[0], x: r[1], y: r[2] }));
  }

  if (p === '/api/swipe' && req.method === 'POST') {
    const b = await readBody(req);
    const r = bridge.swipe(b.x1 | 0, b.y1 | 0, b.x2 | 0, b.y2 | 0, b.dur == null ? 0.2 : b.dur);
    return send(res, 200, JSON.stringify({ ok: !!r }));
  }

  if (p === '/api/tap' && req.method === 'POST') {
    const b = await readBody(req);
    const r = bridge.tap(b.x | 0, b.y | 0);
    return send(res, 200, JSON.stringify({ ok: !!r }));
  }

  if (p === '/api/swipe' && req.method === 'POST') {
    const b = await readBody(req);
    const r = bridge.swipe(b.x1 | 0, b.y1 | 0, b.x2 | 0, b.y2 | 0, b.dur == null ? 0.3 : b.dur);
    return send(res, 200, JSON.stringify({ ok: !!r }));
  }

  if (p === '/api/run' && req.method === 'POST') {
    // 双端设备引擎 run（base64）
    const b = await readBody(req);
    const b64 = Buffer.from(String(b.code || ''), 'utf8').toString('base64');
    const out = await engineSock('run ' + b64, 60000);
    if (!out) return send(res, 502, JSON.stringify({ ok: false, error: 'run 失败（设备无响应或脚本超时）' }));
    try { return send(res, 200, String(out)); } catch (_) { return send(res, 200, String(out), 'text/plain; charset=utf-8'); }
  }

  send(res, 404, JSON.stringify({ error: 'not found' }));
});

// ---- LSP 桥：/ws/lsp WebSocket <-> lua-language-server stdio（零依赖 WS 实现）----
const crypto = require('crypto');
const { spawn } = require('child_process');
const LSP_EXE = path.join(__dirname, 'lsp', 'lls', 'bin', 'lua-language-server.exe');
const LSP_META = path.join(__dirname, 'lsp', 'meta'); // MatisuAuto API 注解目录
const LSP_SCRIPTS = path.join(__dirname, 'scripts');

// 关键：LLS 只认 workspace root（rootUri=scripts/）下的 .luarc.json；
// initializationOptions.settings / cwd 下的 luarc 均不生效（实测 3.19.1）。
// 启动时自动生成，把 meta 注解目录挂进 workspace.library。
function ensureLspConfig() {
  try {
    if (!fs.existsSync(LSP_SCRIPTS)) fs.mkdirSync(LSP_SCRIPTS, { recursive: true });
    const luarc = path.join(LSP_SCRIPTS, '.luarc.json');
    const want = JSON.stringify({
      'runtime.version': 'Lua 5.4',
      'workspace.library': [LSP_META.replace(/\\/g, '/')],
      'workspace.checkThirdParty': false,
      'telemetry.enable': false,
    }, null, 2);
    if (!fs.existsSync(luarc) || fs.readFileSync(luarc, 'utf8') !== want) {
      fs.writeFileSync(luarc, want);
      console.log('[LSP] 已生成 ' + luarc);
    }
  } catch (e) { console.log('[LSP] .luarc.json 生成失败: ' + e.message); }
}
ensureLspConfig();

function wsAccept(key) {
  return crypto.createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
}
/** 解析 WS 帧（客户端→服务端必带掩码）；返回 {opcode, payload} 或 null（数据不足） */
function wsParse(buf) {
  if (buf.length < 2) return null;
  const opcode = buf[0] & 0x0f;
  let len = buf[1] & 0x7f;
  let off = 2;
  if (len === 126) { if (buf.length < 4) return null; len = buf.readUInt16BE(2); off = 4; }
  else if (len === 127) { if (buf.length < 10) return null; len = Number(buf.readBigUInt64BE(2)); off = 10; }
  const masked = (buf[1] & 0x80) !== 0;
  const maskOff = off;
  if (masked) off += 4;
  if (buf.length < off + len) return null;
  let payload = buf.slice(off, off + len);
  if (masked) {
    const mask = buf.slice(maskOff, maskOff + 4);
    payload = Buffer.from(payload);
    for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
  }
  return { opcode, payload, rest: buf.slice(off + len) };
}
function wsFrame(opcode, payload) {
  const len = payload.length;
  let head;
  if (len < 126) { head = Buffer.from([0x80 | opcode, len]); }
  else if (len < 65536) { head = Buffer.alloc(4); head[0] = 0x80 | opcode; head[1] = 126; head.writeUInt16BE(len, 2); }
  else { head = Buffer.alloc(10); head[0] = 0x80 | opcode; head[1] = 127; head.writeBigUInt64BE(BigInt(len), 2); }
  return Buffer.concat([head, payload]);
}

server.on('upgrade', (req, socket) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname !== '/ws/lsp' || !fs.existsSync(LSP_EXE)) { socket.destroy(); return; }
  const key = req.headers['sec-websocket-key'];
  if (!key) { socket.destroy(); return; }
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
    'Upgrade: websocket\r\nConnection: Upgrade\r\n' +
    `Sec-WebSocket-Accept: ${wsAccept(key)}\r\n\r\n`
  );
  socket.setNoDelay(true);

  // 每连接一个 LSP 子进程（单用户 IDE，隔离最稳）
  const child = spawn(LSP_EXE, [], {
    cwd: path.join(__dirname, 'lsp'),
    stdio: ['pipe', 'pipe', 'ignore'],
  });
  child.on('error', () => { try { socket.destroy(); } catch (_) {} });

  // LSP stdout (Content-Length 帧) -> WS text
  let lspBuf = Buffer.alloc(0);
  child.stdout.on('data', (d) => {
    lspBuf = Buffer.concat([lspBuf, d]);
    for (;;) {
      const sep = lspBuf.indexOf('\r\n\r\n');
      if (sep < 0) break;
      const head = lspBuf.slice(0, sep).toString('ascii');
      const m = head.match(/Content-Length:\s*(\d+)/i);
      if (!m) { lspBuf = lspBuf.slice(sep + 4); continue; }
      const n = parseInt(m[1], 10);
      if (lspBuf.length < sep + 4 + n) break;
      const body = lspBuf.slice(sep + 4, sep + 4 + n);
      lspBuf = lspBuf.slice(sep + 4 + n);
      try { socket.write(wsFrame(1, body)); } catch (_) {}
    }
  });

  // WS frame -> LSP stdin
  let wsBuf = Buffer.alloc(0);
  socket.on('data', (d) => {
    wsBuf = Buffer.concat([wsBuf, d]);
    for (;;) {
      const f = wsParse(wsBuf);
      if (!f) break;
      wsBuf = f.rest;
      if (f.opcode === 8) { try { socket.end(); } catch (_) {} continue; } // close
      if (f.opcode === 9) { try { socket.write(wsFrame(10, f.payload)); } catch (_) {} continue; } // ping->pong
      if (f.opcode !== 1 && f.opcode !== 2) continue;
      const head = Buffer.from(`Content-Length: ${f.payload.length}\r\n\r\n`, 'ascii');
      try { child.stdin.write(Buffer.concat([head, f.payload])); } catch (_) {}
    }
  });
  const cleanup = () => { try { child.kill(); } catch (_) {} };
  socket.on('close', cleanup);
  socket.on('error', cleanup);
  child.on('exit', () => { try { socket.end(); } catch (_) {} });

  console.log('[LSP] 会话建立 pid=' + child.pid);
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[MatisuAuto IDE] http://127.0.0.1:${PORT}  (target=${bridge.CFG.target})`);
});
