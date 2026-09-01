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
  else { bridge.CFG.android.device = dev.host + ':' + (dev.port | 0 || 5555); }
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

  // ---- 脚本管理（iOS=设备 scripts 目录；Android=PC 本地 scripts/）----
  const LOCAL_SCRIPTS = path.join(__dirname, 'scripts');
  if (!fs.existsSync(LOCAL_SCRIPTS)) fs.mkdirSync(LOCAL_SCRIPTS, { recursive: true });

  if (p === '/api/scripts') {
    if (bridge.CFG.target === 'android') {
      return send(res, 200, JSON.stringify(fs.readdirSync(LOCAL_SCRIPTS).filter((f) => f.endsWith('.lua'))));
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
      const f = path.join(LOCAL_SCRIPTS, name);
      return send(res, 200, JSON.stringify({ code: fs.existsSync(f) ? fs.readFileSync(f, 'utf8') : '' }));
    }
    // iOS：经 run 指令读设备文件内容
    const rb = Buffer.from(`local f = io.open("/var/mobile/MatisuAuto/scripts/${name}", "r") if f then print(f:read("*a")) f:close() end`, 'utf8').toString('base64');
    const out2 = iosSock('run ' + rb);
    try { const d = JSON.parse(String(out2)); return send(res, 200, JSON.stringify({ code: d.output || '' })); }
    catch (_) { return send(res, 200, '{"code":""}'); }
  }

  if (p === '/api/script' && req.method === 'POST') {
    const b = await readBody(req);
    const name = String(b.name || '');
    if (!name || name.includes('..')) return send(res, 400, '{"error":"bad name"}');
    if (bridge.CFG.target === 'android') {
      fs.writeFileSync(path.join(LOCAL_SCRIPTS, name), String(b.code || ''), 'utf8');
      return send(res, 200, '{"ok":true}');
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
      try { fs.unlinkSync(path.join(LOCAL_SCRIPTS, name)); } catch (_) {}
      return send(res, 200, '{"ok":true}');
    }
    const out4 = iosSock('delete ' + name);
    return send(res, 200, JSON.stringify({ ok: String(out4).trim() === 'OK' }));
  }

  if (p === '/api/runfile' && req.method === 'POST') {
    const b = await readBody(req);
    const out5 = iosSock('runfile ' + String(b.name || ''), 60000);
    if (!out5) return send(res, 502, '{"ok":false,"error":"runfile 失败"}');
    return send(res, 200, String(out5));
  }

  if (p === '/api/svc' && req.method === 'POST') {
    // 常驻控制：{action: start|stop|state, code?}
    const b = await readBody(req);
    let out6;
    if (b.action === 'start') out6 = iosSock('start ' + Buffer.from(String(b.code || ''), 'utf8').toString('base64'));
    else if (b.action === 'stop') out6 = iosSock('stop');
    else out6 = iosSock('state');
    if (b.action === 'state') { try { return send(res, 200, String(out6)); } catch (_) { return send(res, 200, '{}'); } }
    return send(res, 200, JSON.stringify({ ok: String(out6).trim() === 'OK' }));
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
    // iOS：设备端 run（base64）；Android：暂提示走 runner
    const b = await readBody(req);
    if (bridge.CFG.target === 'android') {
      return send(res, 200, JSON.stringify({ ok: false, error: 'Android 脚本运行请用 runner.js（IDE 内运行暂仅支持 iOS 设备端）' }));
    }
    const b64 = Buffer.from(String(b.code || ''), 'utf8').toString('base64');
    const out = iosSock('run ' + b64, 60000);
    if (!out) return send(res, 502, JSON.stringify({ ok: false, error: 'run 失败（设备无响应或脚本超时）' }));
    try { return send(res, 200, String(out)); } catch (_) { return send(res, 200, String(out), 'text/plain; charset=utf-8'); }
  }

  send(res, 404, JSON.stringify({ error: 'not found' }));
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[MatisuAuto IDE] http://127.0.0.1:${PORT}  (target=${bridge.CFG.target})`);
});
