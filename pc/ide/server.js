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

  // ---- 脚本管理（iOS=设备 scripts 目录；Android=PC 本地 scripts/）----
  const LOCAL_SCRIPTS = path.join(__dirname, 'scripts');
  if (!fs.existsSync(LOCAL_SCRIPTS)) fs.mkdirSync(LOCAL_SCRIPTS, { recursive: true });

  if (p === '/api/scripts') {
    if (bridge.CFG.target === 'android') {
      return send(res, 200, JSON.stringify(fs.readdirSync(LOCAL_SCRIPTS).filter((f) => f.endsWith('.lua'))));
    }
    const out = iosSock('list');
    try { JSON.parse(String(out)); return send(res, 200, String(out)); } catch (_) { return send(res, 200, '[]'); }
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

  if (p === '/api/tap' && req.method === 'POST') {
    const b = await readBody(req);
    const r = bridge.tap(b.x | 0, b.y | 0);
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
