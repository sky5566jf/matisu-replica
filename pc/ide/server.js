// MatisuAuto PC IDE —— 零依赖 node 后端（取色器 + 脚本运行）
// 用法：node server.js [port]   默认 5586；浏览器开 http://127.0.0.1:5586
// 设备切换：页面内 iOS/Android 按钮（服务端改 bridge.CFG.target）
const http = require('http');
const zlib = require('zlib');
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
  res.writeHead(code, { 'Content-Type': type, 'Access-Control-Allow-Origin': '*', 'Cache-Control': 'no-cache, no-store, must-revalidate' });
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
  if (p === '/queseqi' || p === '/zhuazhua') return send(res, 200, fs.readFileSync(path.join(__dirname, 'queseqi.html')), 'text/html; charset=utf-8');
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

  // 打开本地脚本工作区目录（状态栏「打开目录」）
  if (p === '/api/opendir') {
    const dir = path.join(__dirname, 'scripts');
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    try {
      require('child_process').exec(`explorer "${dir}"`);
      return send(res, 200, JSON.stringify({ ok: true, path: dir }));
    } catch (e) { return send(res, 500, JSON.stringify({ error: e.message })); }
  }

  // ---- 帮助文档：从 懒人精灵技能/ios/*.md 解析每个函数的语法/说明/示例 ----
  if (!global.__HELP_CACHE__) {
    global.__HELP_CACHE__ = (() => {
      const dir = path.resolve(__dirname, '..', '..', '..', '懒人精灵技能', 'ios');
      const cache = new Map();
      if (!fs.existsSync(dir)) return cache;
      const codeOf = (text) => (text.match(/```[\s\S]*?```/) || [''])[0].replace(/```\w*\n?|```/g, '').trim();
      const parseParams = (text) => {
        // 元键（不是参数）
        const META = new Set(['方法名称', '语法', '参数说明', '参数', '返回值', '备注', '示例', '说明', '来源']);
        const out = [];
        text.replace(/\r\n/g, '\n').split('\n').forEach((ln) => {
          const m = ln.match(/^\s*-\s*([\w\u4e00-\u9fa5][^：:]*)[：:]\s*(.*)$/);
          if (m && !META.has(m[1].trim())) out.push({ k: m[1].trim(), v: m[2].trim() });
        });
        return out;
      };
      for (const file of fs.readdirSync(dir).filter((f) => f.endsWith('.md'))) {
        const src = fs.readFileSync(path.join(dir, file), 'utf8');
        const parts = src.split(/^##\s+/m);
        for (const seg of parts.slice(1)) {
          const nl = seg.indexOf('\n');
          const head = seg.slice(0, nl === -1 ? seg.length : nl).trim();
          const sp = head.indexOf(' ');
          const name = (sp === -1 ? head : head.slice(0, sp)).trim();
          const title = (sp === -1 ? '' : head.slice(sp + 1)).trim();
          if (!name) continue;
          const body = seg.slice(nl + 1);
          const blocks = { syntax: '', desc: '', params: [], returns: [], example: '', note: '' };
          const re = /\*\*(语法|说明|参数说明|返回值|备注|示例)\*\*\s*\n([\s\S]*?)(?=\n\*\*|\n## |\s*$)/g;
          let m;
          while ((m = re.exec(body))) {
            const tag = m[1];
            const val = m[2].trim();
            if (tag === '参数说明') blocks.params = parseParams(val);
            else if (tag === '返回值') blocks.returns = parseParams(val);
            else if (tag === '语法') blocks.syntax = codeOf(val);
            else if (tag === '示例') blocks.example = codeOf(val);
            else if (tag === '说明') {
              blocks.desc = val;
              // 不少函数把参数/返回值嵌在「说明」块里，再抽一次（独立参数块会优先覆盖）
              const ps = parseParams(val);
              const rsRaw = val.split('\n').filter((l) => /^\s*-\s*返回值\s*[:：]/.test(l));
              if (ps.length && !blocks.params.length) blocks.params = ps;
              // 返回值描述（一般是单个「无」或字符串型描述）
              if (!blocks.returns.length && rsRaw.length) {
                blocks.returns = rsRaw.map((l) => ({ k: '返回值', v: l.replace(/^\s*-\s*返回值\s*[:：]\s*/, '').trim() }));
              }
            }
            else blocks.note = val;
          }
          if (!title && blocks.desc) {
            const f = blocks.desc.split('\n').find((l) => l.includes('方法名称')) || '';
            const t = f.match(/方法名称\s*[:：]\s*(.+)/);
            if (t) blocks.title = t[1].trim();
          }
          cache.set(name, { name, title: title || blocks.title || '', source: file, ...blocks });
        }
      }
      return cache;
    })();
  }
  if (p === '/api/help') {
    const name = u.searchParams.get('name') || '';
    const short = name.split('.').pop();
    const info = global.__HELP_CACHE__.get(name) || global.__HELP_CACHE__.get(short);
    return send(res, 200, JSON.stringify(info ? { ok: true, info } : { ok: false, name }));
  }
  if (p === '/api/help-list') {
    const names = [...global.__HELP_CACHE__.keys()].sort();
    return send(res, 200, JSON.stringify({ ok: true, names }));
  }

  // ---- API 契约清单（从 core.lua 解析：分节注释 + _stub 函数名 + 表方法，注释作描述）----
  // 中文描述优先级：懒人精灵技能/ios/*.md 的帮助标题 > core.lua 紧邻注释 > 空
  if (p === '/api/apis') {
    try {
      const core = fs.readFileSync(path.join(__dirname, '..', '..', 'common', 'lua-api', 'core.lua'), 'utf8');
      const sections = [];
      let cur = { name: '全局', fns: [] };
      let comments = [];                     // 累积的紧邻注释行
      const helpTitle = (name) => {
        const short = name.split('.').pop();
        const info = global.__HELP_CACHE__ && (global.__HELP_CACHE__.get(name) || global.__HELP_CACHE__.get(short));
        return (info && info.title) || '';
      };
      const descFor = (name) => {
        const ht = helpTitle(name);
        if (ht) return ht.length > 60 ? ht.slice(0, 60) + '…' : ht;
        // 优先取以函数名开头的注释行，剥掉名字前缀后作为描述
        let line = comments.find((c) => c.startsWith(name)) || comments[comments.length - 1] || '';
        line = line.replace(new RegExp('^' + name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\s*'), '');
        line = line.replace(/^[：:]\s*/, '').trim();
        return line.length > 60 ? line.slice(0, 60) + '…' : line;
      };
      const pushFn = (name) => cur.fns.push({ n: name, d: descFor(name) });
      for (const line of core.split('\n')) {
        const t = line.trim();
        const sec = t.match(/^--\s*[一二三四五六七八九十]+、(.+)$/);
        if (sec) { if (cur.fns.length) sections.push(cur); cur = { name: sec[1].trim(), fns: [] }; comments = []; continue; }
        if (t.startsWith('--')) {
          const c = t.replace(/^--+\s*/, '');
          if (c && !/^[-=]+$/.test(c)) comments.push(c);
          continue;
        }
        if (!t) continue;
        const m = t.match(/_stub\("([^"]+)"\)/);
        if (m) { pushFn(m[1]); comments = []; continue; }
        const m2 = t.match(/^\s*(?:function\s+)?(?:jsonLib|imeLib|ImageUtil|ui|nodeLib|strutils|cryptLib|console|lfs|json|cipher|network)\.(\w+)/);
        if (m2) { pushFn(t.trim().split('.')[0].replace(/^\W+/, '') + '.' + m2[1]); comments = []; continue; }
        // 模块表打开行（cipher = { 等）不断开注释——表内首个条目要用表前的注释
        if (/^\s*[\w.]+\s*=\s*\{\s*$/.test(t)) continue;
        comments = [];   // 普通代码行隔断注释
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

  // ---- 设备搜索（本地连接：扫局域网 18182/18183 引擎端口）----
  const SCAN_STATE = { running: false, stop: false, found: [] };
  function localSubnets() {
    const out = new Set();
    const ifs = os.networkInterfaces();
    for (const k in ifs) for (const it of ifs[k]) {
      if (it.family === 'IPv4' && !it.internal) {
        const m = it.address.match(/^(\d+\.\d+)\.\d+\.\d+$/);
        if (m) out.add(m[1]);
      }
    }
    return [...out];
  }
  function probePort(host, port, timeout = 400) {
    return new Promise((resolve) => {
      const s = new net.Socket();
      const done = (v) => { try { s.destroy(); } catch (_) {} resolve(v); };
      s.setTimeout(timeout);
      s.once('connect', () => done(true));
      s.once('timeout', () => done(false));
      s.once('error', () => done(false));
      s.connect(port, host);
    });
  }
  async function runScan() {
    SCAN_STATE.running = true; SCAN_STATE.stop = false; SCAN_STATE.found = [];
    const subs = localSubnets();
    const jobs = [];
    for (const sub of subs) {
      for (let i = 1; i <= 254; i++) {
        const host = `${sub}.${i}`;
        for (const port of [18182, 18183]) jobs.push({ host, port });
      }
    }
    const CONC = 160;
    let idx = 0;
    async function worker() {
      while (!SCAN_STATE.stop && idx < jobs.length) {
        const j = jobs[idx++];
        if (await probePort(j.host, j.port)) {
          if (!SCAN_STATE.found.some((x) => x.host === j.host)) SCAN_STATE.found.push({ host: j.host, port: j.port });
        }
      }
    }
    await Promise.all(Array.from({ length: CONC }, worker));
    SCAN_STATE.running = false;
  }
  if (p === '/api/scan' && req.method === 'POST') {
    const b = await readBody(req);
    if (b.op === 'start') {
      if (!SCAN_STATE.running) runScan();   // 异步跑，前端轮询
      return send(res, 200, JSON.stringify({ ok: true, running: true }));
    }
    if (b.op === 'stop') { SCAN_STATE.stop = true; return send(res, 200, JSON.stringify({ ok: true, running: false })); }
    return send(res, 400, '{"error":"op 必填"}');
  }
  if (p === '/api/scan' && req.method === 'GET') {
    return send(res, 200, JSON.stringify({ running: SCAN_STATE.running, found: SCAN_STATE.found }));
  }

  // ---- 工程管理（多工程 + 活动工程：仅 脚本/main.lua + 资源/main.rc）----
  const PROJECT_FILE = path.join(__dirname, 'project.json');
  // 被"仅移除"（未彻底删除）的工程记录；重新添加时从这里恢复
  const HIDDEN_FILE = path.join(__dirname, 'hidden_projects.json');
  const normP = (s) => String(s || '').replace(/[\\/]/g, '/').toLowerCase();
  function loadHidden() {
    try { const v = JSON.parse(fs.readFileSync(HIDDEN_FILE, 'utf8')); return Array.isArray(v) ? v : []; } catch (_) { return []; }
  }
  function saveHidden(list) { try { fs.writeFileSync(HIDDEN_FILE, JSON.stringify(list, null, 2), 'utf8'); } catch (_) {} }
  // 原始请求体读取（工程导入：浏览器前端逐文件上传二进制）
  function readRawBody(req) {
    return new Promise((resolve) => {
      const chunks = [];
      req.on('data', (c) => chunks.push(c));
      req.on('end', () => resolve(Buffer.concat(chunks)));
      req.on('error', () => resolve(Buffer.alloc(0)));
    });
  }
  // 所有工程都放在 workspace/ 下，命名为 workspace/<工程名>/；project.json 仅记"当前活动"工程
  const WORKSPACE_DIR = path.join(__dirname, 'workspace');
  if (!fs.existsSync(WORKSPACE_DIR)) fs.mkdirSync(WORKSPACE_DIR, { recursive: true });
  function loadProject() { try { const v = JSON.parse(fs.readFileSync(PROJECT_FILE, 'utf8')); return (v && typeof v === 'object') ? v : null; } catch (_) { return null; } }
  function saveProject(pj) { fs.writeFileSync(PROJECT_FILE, JSON.stringify(pj, null, 2), 'utf8'); }
  function listWorkspaceProjects() {
    // 扫描 workspace/，每个子目录视为一个工程；显示名=目录名；状态=是否为活动工程
    let entries = [];
    try { entries = fs.readdirSync(WORKSPACE_DIR, { withFileTypes: true }); } catch (_) { return []; }
    const cur = loadProject();
    const curRoot = cur && cur.root ? path.resolve(cur.root) : null;
    const hidden = new Set(loadHidden().map((h) => normP(h.root)));
    return entries.filter((e) => e.isDirectory())
      .map((e) => {
        const root = path.join(WORKSPACE_DIR, e.name);
        return { name: e.name, root, active: path.resolve(root) === curRoot };
      })
      .filter((p) => !hidden.has(normP(p.root)))
      .sort((a, b) => a.name.localeCompare(b.name, 'zh'));
  }
  // 已移除但仍存在于磁盘的工程（可在"打开工程"里重新添加）
  function listHiddenProjects() {
    return loadHidden()
      .filter((h) => h && h.root && fs.existsSync(h.root))
      .map((h) => ({ name: path.basename(h.root), root: h.root, removedAt: h.removedAt || null }));
  }
  // 移除活动工程后自动挑一个可用工程顶上（没有则清空）
  function pickAnotherActive(excludeNorm) {
    const rest = listWorkspaceProjects().filter((p) => normP(p.root) !== excludeNorm);
    if (!rest.length) { saveProject(null); return null; }
    saveProject({ root: rest[0].root, name: rest[0].name });
    return rest[0];
  }
  function buildTree(root, rel = '') {
    const abs = rel ? path.join(root, rel) : root;
    const out = [];
    let entries = [];
    try { entries = fs.readdirSync(abs, { withFileTypes: true }); } catch (_) { return out; }
    const dirs = entries.filter((e) => e.isDirectory() && e.name !== 'node_modules').map((e) => e.name).sort((a, b) => a.localeCompare(b, 'zh'));
    const fils = entries.filter((e) => e.isFile()).map((e) => e.name).sort((a, b) => a.localeCompare(b, 'zh'));
    for (const d of dirs) {
      const r = rel ? rel + '/' + d : d;
      out.push({ n: d, d: 1, p: r, c: buildTree(root, r) });
    }
    for (const f of fils) out.push({ n: f, p: rel ? rel + '/' + f : f });
    return out;
  }
  function resolveProjPath(rel) {
    const pj = loadProject();
    if (!pj || !pj.root) return null;
    const rp = String(rel || '');
    if (!rp || rp.includes('..') || rp.includes('\\')) return null;
    // 统一为绝对路径再比较（兼容 project.json 里正/反斜杠混写）
    const rootAbs = path.resolve(pj.root);
    const abs = path.resolve(rootAbs, rp);
    const relCheck = path.relative(rootAbs, abs);
    if (!relCheck || relCheck.startsWith('..') || path.isAbsolute(relCheck)) return null;
    return { pj, abs };
  }
  if (p === '/api/project' && req.method === 'GET') {
    const pj = loadProject();
    const projects = listWorkspaceProjects();
    if (!pj || !pj.root || !fs.existsSync(pj.root)) {
      return send(res, 200, JSON.stringify({ ok: false, projects }));
    }
    return send(res, 200, JSON.stringify({ ok: true, root: pj.root, name: pj.name, tree: buildTree(pj.root), projects }));
  }

  // ---- 全局搜索：检索当前工程所有文本文件（对齐原版"查找本工程"）----
  if (p === '/api/search' && req.method === 'GET') {
    const q = (u.searchParams.get('q') || '').trim();
    const pj = loadProject();
    if (!q || !pj || !pj.root || !fs.existsSync(pj.root)) return send(res, 200, JSON.stringify({ ok: false, hits: [] }));
    const TEXT_EXT = /\.(lua|html?|ui|json|loprojit|txt|md|css|js)$/i;
    const SKIP_DIR = /^(node_modules|cache|\.git)$/i;
    const hits = [];
    const rootAbs = path.resolve(pj.root);
    const walk = (rel) => {
      if (hits.length >= 500) return;
      const abs = rel ? path.join(rootAbs, rel) : rootAbs;
      let entries = [];
      try { entries = fs.readdirSync(abs, { withFileTypes: true }); } catch (_) { return; }
      for (const e of entries) {
        if (hits.length >= 500) return;
        const rp = rel ? rel + '/' + e.name : e.name;
        if (e.isDirectory()) { if (!SKIP_DIR.test(e.name)) walk(rp); continue; }
        if (!e.isFile() || !TEXT_EXT.test(e.name)) continue;
        let content = '';
        try {
          const st = fs.statSync(path.join(rootAbs, rp));
          if (st.size > 2 * 1024 * 1024) continue;
          content = fs.readFileSync(path.join(rootAbs, rp), 'utf8');
        } catch (_) { continue; }
        const ql = q.toLowerCase();
        content.split('\n').forEach((line, i) => {
          if (hits.length < 500 && line.toLowerCase().includes(ql)) {
            hits.push({ f: rp, l: i + 1, t: line.trim().slice(0, 120) });
          }
        });
      }
    };
    walk('');
    return send(res, 200, JSON.stringify({ ok: true, hits }));
  }
  if (p === '/api/project/new' && req.method === 'POST') {
    const b = await readBody(req);
    const name = String(b.name || '').trim().replace(/[\\/:*?"<>|]/g, '_');
    if (!name) return send(res, 400, JSON.stringify({ error: '项目名称必填' }));
    const root = path.join(WORKSPACE_DIR, name);
    if (fs.existsSync(root)) return send(res, 400, JSON.stringify({ error: '已存在同名工程（' + name + '）' }));
    try {
      for (const d of ['脚本', '资源']) {
        fs.mkdirSync(path.join(root, d), { recursive: true });
      }
      const w = (r, s) => { const f = path.join(root, r); if (!fs.existsSync(f)) fs.writeFileSync(f, s, 'utf8'); };
      w('脚本/main.lua', `-- ${name} 主脚本\n-- 入口：installpkg 打包后自启动从此文件执行\n\nprint("${name} started")\n`);
      w('资源/main.rc', '');
      saveProject({ root, name });
      return send(res, 200, JSON.stringify({ ok: true, root, name, tree: buildTree(root) }));
    } catch (e) { return send(res, 500, JSON.stringify({ error: e.message })); }
  }
  if (p === '/api/project/importbegin' && req.method === 'POST') {
    // 前端通过 <input webkitdirectory> 弹系统文件夹选择框后，分片上传导入工程。
    // begin：同名工程已在 workspace/ → 不再导入，直接返回其信息让前端打开（"列表已有就不导入"）
    const b = await readBody(req);
    const name = String(b.name || '').trim().replace(/[\\/:*?"<>|]/g, '_');
    if (!name) return send(res, 400, JSON.stringify({ ok: false, error: '工程名缺失' }));
    const dest = path.join(path.resolve(WORKSPACE_DIR), name);
    if (fs.existsSync(dest)) {
      // 已在列表（含曾被"仅移除"的）：不导入，重新加入列表并直接打开
      const key = normP(dest);
      saveHidden(loadHidden().filter((h) => normP(h.root) !== key));
      saveProject({ root: dest, name });
      return send(res, 200, JSON.stringify({
        ok: true, exists: true, root: dest, name, tree: buildTree(dest),
        message: '工程「' + name + '」已在列表中，不重复导入，已直接打开'
      }));
    }
    try { fs.mkdirSync(dest, { recursive: true }); } catch (e) { return send(res, 500, JSON.stringify({ ok: false, error: e.message })); }
    return send(res, 200, JSON.stringify({ ok: true, exists: false, name }));
  }
  if (p === '/api/project/importfile' && req.method === 'POST') {
    // 逐文件上传：写入 workspace/<name>/<rel>
    const u = new URL(req.url, 'http://x');
    const name = decodeURIComponent(u.searchParams.get('name') || '').replace(/[\\/:*?"<>|]/g, '_');
    const rel = decodeURIComponent(u.searchParams.get('path') || '').replace(/\\/g, '/');
    if (!name || !rel) return send(res, 400, JSON.stringify({ ok: false, error: 'name/path 必填' }));
    if (rel.split('/').some((seg) => !seg || seg === '.' || seg === '..')) return send(res, 400, JSON.stringify({ ok: false, error: '非法路径: ' + rel }));
    const dest = path.join(path.resolve(WORKSPACE_DIR), name, rel);
    const wsAbs = path.resolve(WORKSPACE_DIR);
    if (path.relative(wsAbs, dest).startsWith('..')) return send(res, 400, JSON.stringify({ ok: false, error: '路径越界' }));
    const buf = await readRawBody(req);
    try {
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      fs.writeFileSync(dest, buf);
    } catch (e) { return send(res, 500, JSON.stringify({ ok: false, error: e.message })); }
    return send(res, 200, JSON.stringify({ ok: true }));
  }
  if (p === '/api/project/importend' && req.method === 'POST') {
    // 导入收尾：设为活动工程，返回工程树
    const b = await readBody(req);
    const name = String(b.name || '').trim().replace(/[\\/:*?"<>|]/g, '_');
    const dest = path.join(path.resolve(WORKSPACE_DIR), name);
    if (!name || !fs.existsSync(dest)) return send(res, 400, JSON.stringify({ ok: false, error: '导入目录不存在: ' + name }));
    saveProject({ root: dest, name });
    return send(res, 200, JSON.stringify({ ok: true, root: dest, name, tree: buildTree(dest), message: '已导入工程「' + name + '」并打开' }));
  }
  if (p === '/api/projects' && req.method === 'GET') {
    // 列出 workspace/ 全部工程 + 当前活动
    try {
      const cur = loadProject();
      const projects = listWorkspaceProjects();
      return send(res, 200, JSON.stringify({ ok: true, active: (cur && cur.name) || null, projects, hidden: listHiddenProjects() }));
    } catch (e) { return send(res, 500, JSON.stringify({ error: e.message })); }
  }
  if (p === '/api/project/select' && req.method === 'POST') {
    // 切换活动工程（不复制目录，只把 root 写到 project.json）
    const b = await readBody(req);
    const root = String(b.root || '').trim();
    if (!root) return send(res, 400, JSON.stringify({ error: 'root 必填' }));
    if (!fs.existsSync(root)) return send(res, 400, JSON.stringify({ error: '目录不存在: ' + root }));
    const name = path.basename(root);
    saveProject({ root, name });
    return send(res, 200, JSON.stringify({ ok: true, root, name, tree: buildTree(root) }));
  }
  if (p === '/api/project/remove' && req.method === 'POST') {
    // 移除工程。purge=true 彻底删除磁盘目录；purge=false 仅从列表移除（文件保留，可在"打开工程"里重新添加）
    const b = await readBody(req);
    const root = String(b.root || '').trim();
    const purge = !!b.purge;
    if (!root) return send(res, 400, JSON.stringify({ error: 'root 必填' }));
    const rootAbs = path.resolve(root);
    const wsAbs = path.resolve(WORKSPACE_DIR);
    // 安全闸：只允许操作 workspace/ 下的目录
    const rel = path.relative(wsAbs, rootAbs);
    if (rel.startsWith('..') || path.isAbsolute(rel) || !rel) return send(res, 400, JSON.stringify({ error: '仅允许移除 workspace/ 下的工程' }));
    if (!fs.existsSync(rootAbs)) return send(res, 400, JSON.stringify({ error: '目录不存在' }));
    try {
      const key = normP(rootAbs);
      if (purge) {
        fs.rmSync(rootAbs, { recursive: true, force: true });
        saveHidden(loadHidden().filter((h) => normP(h.root) !== key));
      } else {
        const list = loadHidden();
        if (!list.some((h) => normP(h.root) === key)) {
          list.push({ name: path.basename(rootAbs), root: rootAbs, removedAt: new Date().toISOString() });
        }
        saveHidden(list);
      }
      const cur = loadProject();
      let switched = null;
      if (cur && cur.root && path.resolve(cur.root) === rootAbs) switched = pickAnotherActive(key);
      return send(res, 200, JSON.stringify({ ok: true, purged: purge, switched: switched ? { root: switched.root, name: switched.name } : null }));
    } catch (e) { return send(res, 500, JSON.stringify({ error: e.message })); }
  }
  if (p === '/api/project/restore' && req.method === 'POST') {
    // 重新添加"仅移除"的工程（文件一直在磁盘上），并设为活动工程
    const b = await readBody(req);
    const root = String(b.root || '').trim();
    if (!root) return send(res, 400, JSON.stringify({ error: 'root 必填' }));
    const rootAbs = path.resolve(root);
    const wsAbs = path.resolve(WORKSPACE_DIR);
    const rel = path.relative(wsAbs, rootAbs);
    if (rel.startsWith('..') || path.isAbsolute(rel) || !rel) return send(res, 400, JSON.stringify({ error: '仅允许添加 workspace/ 下的工程' }));
    if (!fs.existsSync(rootAbs)) {
      saveHidden(loadHidden().filter((h) => normP(h.root) !== normP(rootAbs)));
      return send(res, 400, JSON.stringify({ error: '目录已不存在（可能已被彻底删除）' }));
    }
    saveHidden(loadHidden().filter((h) => normP(h.root) !== normP(rootAbs)));
    const name = path.basename(rootAbs);
    saveProject({ root: rootAbs, name });
    return send(res, 200, JSON.stringify({ ok: true, root: rootAbs, name, tree: buildTree(rootAbs) }));
  }
  if (p === '/api/project/rename' && req.method === 'POST') {
    const b = await readBody(req);
    const oldPath = String(b.oldPath || '').trim();
    const newPath = String(b.newPath || '').trim();
    if (!oldPath || !newPath) return send(res, 400, JSON.stringify({ error: '原路径与新路径必填' }));
    const oldAbs = path.resolve(oldPath);
    const newAbs = path.resolve(newPath);
    const wsAbs = path.resolve(WORKSPACE_DIR);
    for (const a of [oldAbs, newAbs]) {
      const r = path.relative(wsAbs, a);
      if (r.startsWith('..') || path.isAbsolute(r) || !r) return send(res, 400, JSON.stringify({ error: '仅允许在 workspace/ 下重命名' }));
    }
    if (!fs.existsSync(oldAbs)) return send(res, 400, JSON.stringify({ error: '源目录不存在' }));
    if (fs.existsSync(newAbs)) return send(res, 400, JSON.stringify({ error: '目标目录已存在' }));
    try {
      fs.renameSync(oldAbs, newAbs);
      const cur = loadProject();
      if (cur && cur.root && path.resolve(cur.root) === oldAbs) {
        saveProject({ root: newPath.replace(/\//g, path.sep), name: path.basename(newAbs) });
      }
      return send(res, 200, JSON.stringify({ ok: true }));
    } catch (e) { return send(res, 500, JSON.stringify({ error: e.message })); }
  }
  if (p === '/api/proj-reveal' && req.method === 'POST') {
    const b = await readBody(req);
    const root = String(b.root || '').trim();
    if (!root || !fs.existsSync(root)) return send(res, 400, JSON.stringify({ error: '目录不存在' }));
    try {
      const { execFileSync } = require('child_process');
      execFileSync('explorer.exe', [path.normalize(root)], { stdio: 'ignore' });
      return send(res, 200, JSON.stringify({ ok: true }));
    } catch (e) { return send(res, 500, JSON.stringify({ error: e.message })); }
  }
  if (p === '/api/open-app-window' && req.method === 'POST') {
    // 以浏览器「应用窗口(--app)」模式打开 IDE：无地址栏/标签栏，
    // Ctrl+E 之类浏览器级快捷键不会再被 omnibox 抢走。
    try {
      const { spawn } = require('child_process');
      const pf = process.env['ProgramFiles'] || 'C:/Program Files';
      const pf86 = process.env['ProgramFiles(x86)'] || 'C:/Program Files (x86)';
      const la = process.env.LOCALAPPDATA || '';
      const cands = [
        path.join(pf, 'Google/Chrome/Application/chrome.exe'),
        path.join(pf86, 'Google/Chrome/Application/chrome.exe'),
        la ? path.join(la, 'Google/Chrome/Application/chrome.exe') : '',
        path.join(pf86, 'Microsoft/Edge/Application/msedge.exe'),
        path.join(pf, 'Microsoft/Edge/Application/msedge.exe'),
      ].filter(Boolean);
      const exe = cands.find((f) => fs.existsSync(f));
      if (!exe) return send(res, 200, JSON.stringify({ ok: false, error: '未找到 Chrome/Edge' }));
      spawn(exe, [`--app=http://127.0.0.1:${PORT}/`, '--window-size=1400,900'], { detached: true, stdio: 'ignore' }).unref();
      return send(res, 200, JSON.stringify({ ok: true, exe }));
    } catch (e) { return send(res, 500, JSON.stringify({ error: e.message })); }
  }
  if (p === '/api/browse' && req.method === 'GET') {
    // 文件夹浏览器：{p} 为目录绝对路径；默认 F:/workbuddy
    let dir = u.searchParams.get('p') || 'F:/workbuddy';
    try {
      const st = fs.statSync(dir);
      if (!st.isDirectory()) dir = path.dirname(dir);
      const entries = fs.readdirSync(dir, { withFileTypes: true })
        .filter((e) => e.isDirectory()).map((e) => e.name).sort((a, b2) => a.localeCompare(b2, 'zh'));
      return send(res, 200, JSON.stringify({ ok: true, path: dir, parent: path.dirname(dir) !== dir ? path.dirname(dir) : null, dirs: entries }));
    } catch (e) { return send(res, 200, JSON.stringify({ ok: false, error: e.message, path: dir, dirs: [] })); }
  }
  if (p === '/api/file' && req.method === 'GET') {
    const r = resolveProjPath(u.searchParams.get('p'));
    if (!r) return send(res, 400, '{"error":"bad path"}');
    try { return send(res, 200, JSON.stringify({ ok: true, code: fs.readFileSync(r.abs, 'utf8') })); }
    catch (e) { return send(res, 200, JSON.stringify({ ok: false, code: '' })); }
  }
  if (p === '/api/file' && req.method === 'POST') {
    const b = await readBody(req);
    const r = resolveProjPath(b.p);
    if (!r) return send(res, 400, '{"error":"bad path"}');
    try {
      fs.mkdirSync(path.dirname(r.abs), { recursive: true });
      fs.writeFileSync(r.abs, String(b.content == null ? b.code || '' : b.content), 'utf8');
      return send(res, 200, JSON.stringify({ ok: true }));
    } catch (e) { return send(res, 500, JSON.stringify({ error: e.message })); }
  }

  // ---- rc 资源容器（.rc 本质是 zip，运行时直接解包）----
  function zipReadEntries(buf) {
    // 解析 EOCD → 中央目录 → 逐条目；支持 stored + deflate
    const EOCD = 0x06054b50, CDH = 0x02014b50, LFH = 0x04034b50;
    let eocd = -1;
    for (let i = buf.length - 22; i >= Math.max(0, buf.length - 22 - 65536); i--) {
      if (buf.readUInt32LE(i) === EOCD) { eocd = i; break; }
    }
    if (eocd < 0) throw new Error('不是有效的 zip/rc 文件');
    const count = buf.readUInt16LE(eocd + 10);
    let off = buf.readUInt32LE(eocd + 16);
    const out = [];
    for (let i = 0; i < count; i++) {
      if (buf.readUInt32LE(off) !== CDH) break;
      const method = buf.readUInt16LE(off + 10);
      const csize = buf.readUInt32LE(off + 20);
      const usize = buf.readUInt32LE(off + 24);
      const nlen = buf.readUInt16LE(off + 28);
      const elen = buf.readUInt16LE(off + 30);
      const clen = buf.readUInt16LE(off + 32);
      const lfhOff = buf.readUInt32LE(off + 42);
      const name = buf.slice(off + 46, off + 46 + nlen).toString('utf8');
      const lNlen = buf.readUInt16LE(lfhOff + 26), lElen = buf.readUInt16LE(lfhOff + 28);
      const dataStart = lfhOff + 30 + lNlen + lElen;
      const raw = buf.slice(dataStart, dataStart + csize);
      let data;
      if (method === 0) data = Buffer.from(raw);
      else if (method === 8) data = zlib.inflateRawSync(raw);
      else data = null;
      out.push({ name, size: usize, data });
      off += 46 + nlen + elen + clen;
    }
    return out;
  }
  function zipWriteEntries(entries) {
    // entries: [{name, data(Buffer)}] → deflate + 完整 zip 缓冲
    const parts = [], central = [];
    let offset = 0;
    const now = new Date();
    const dosTime = ((now.getHours() << 11) | (now.getMinutes() << 5) | (now.getSeconds() >> 1)) & 0xffff;
    const dosDate = (((now.getFullYear() - 1980) << 9) | ((now.getMonth() + 1) << 5) | now.getDate()) & 0xffff;
    for (const e of entries) {
      const nameBuf = Buffer.from(e.name, 'utf8');
      const comp = zlib.deflateRawSync(e.data, { level: 6 });
      const useDef = comp.length < e.data.length;
      const payload = useDef ? comp : e.data;
      const method = useDef ? 8 : 0;
      const crc = zlib.crc32 ? zlib.crc32(e.data) >>> 0 : crc32fallback(e.data);
      const lfh = Buffer.alloc(30);
      lfh.writeUInt32LE(0x04034b50, 0);
      lfh.writeUInt16LE(20, 4);
      lfh.writeUInt16LE(0x0800, 6);          // UTF-8 名
      lfh.writeUInt16LE(method, 8);
      lfh.writeUInt16LE(dosTime, 10); lfh.writeUInt16LE(dosDate, 12);
      lfh.writeUInt32LE(crc, 14);
      lfh.writeUInt32LE(payload.length, 18);
      lfh.writeUInt32LE(e.data.length, 22);
      lfh.writeUInt16LE(nameBuf.length, 26); lfh.writeUInt16LE(0, 28);
      parts.push(lfh, nameBuf, payload);
      const cdh = Buffer.alloc(46);
      cdh.writeUInt32LE(0x02014b50, 0);
      cdh.writeUInt16LE(20, 4); cdh.writeUInt16LE(20, 6);
      cdh.writeUInt16LE(0x0800, 8);
      cdh.writeUInt16LE(method, 10);
      cdh.writeUInt16LE(dosTime, 12); cdh.writeUInt16LE(dosDate, 14);
      cdh.writeUInt32LE(crc, 16);
      cdh.writeUInt32LE(payload.length, 20);
      cdh.writeUInt32LE(e.data.length, 24);
      cdh.writeUInt16LE(nameBuf.length, 28);
      cdh.writeUInt32LE(offset, 42);
      central.push(Buffer.concat([cdh, nameBuf]));
      offset += lfh.length + nameBuf.length + payload.length;
    }
    const cdBuf = Buffer.concat(central);
    const eocd = Buffer.alloc(22);
    eocd.writeUInt32LE(0x06054b50, 0);
    eocd.writeUInt16LE(entries.length, 8);
    eocd.writeUInt16LE(entries.length, 10);
    eocd.writeUInt32LE(cdBuf.length, 12);
    eocd.writeUInt32LE(offset, 16);
    return Buffer.concat([...parts, cdBuf, eocd]);
  }
  function crc32fallback(buf) {
    let c, crc = 0xffffffff;
    for (let n = 0; n < buf.length; n++) {
      c = (crc ^ buf[n]) & 0xff;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      crc = (crc >>> 8) ^ c;
    }
    return (crc ^ 0xffffffff) >>> 0;
  }
  function loadRc(rel) {
    const r = resolveProjPath(rel);
    if (!r) return null;
    return r;
  }
  const IMG_EXT = ['.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp'];
  if (p === '/api/rc/list' && req.method === 'GET') {
    const r = loadRc(u.searchParams.get('p'));
    if (!r) return send(res, 400, '{"error":"bad path"}');
    try {
      if (!fs.existsSync(r.abs) || fs.statSync(r.abs).size === 0) return send(res, 200, JSON.stringify({ ok: true, entries: [] }));
      const entries = zipReadEntries(fs.readFileSync(r.abs)).map((e) => ({
        name: e.name, size: e.size,
        img: IMG_EXT.includes(path.extname(e.name).toLowerCase()),
      }));
      return send(res, 200, JSON.stringify({ ok: true, entries }));
    } catch (e) { return send(res, 200, JSON.stringify({ ok: false, error: e.message, entries: [] })); }
  }
  if (p === '/api/rc/get' && req.method === 'GET') {
    const r = loadRc(u.searchParams.get('p'));
    const e = u.searchParams.get('e') || '';
    if (!r || !e) return send(res, 400, '{"error":"bad path"}');
    try {
      const ent = zipReadEntries(fs.readFileSync(r.abs)).find((x) => x.name === e);
      if (!ent) return send(res, 404, '{"error":"not found"}');
      return send(res, 200, JSON.stringify({ ok: true, b64: ent.data.toString('base64') }));
    } catch (err) { return send(res, 500, JSON.stringify({ error: err.message })); }
  }
  if (p === '/api/rc/add' && req.method === 'POST') {
    // {p, name, b64}（同名覆盖）
    const b = await readBody(req);
    const r = loadRc(b.p);
    if (!r || !b.name || b.b64 == null) return send(res, 400, '{"error":"bad args"}');
    try {
      let entries = [];
      if (fs.existsSync(r.abs) && fs.statSync(r.abs).size > 0) entries = zipReadEntries(fs.readFileSync(r.abs));
      const data = Buffer.from(b.b64, 'base64');
      entries = entries.filter((x) => x.name !== b.name);
      entries.push({ name: b.name, data });
      fs.mkdirSync(path.dirname(r.abs), { recursive: true });
      fs.writeFileSync(r.abs, zipWriteEntries(entries));
      return send(res, 200, JSON.stringify({ ok: true }));
    } catch (e) { return send(res, 500, JSON.stringify({ error: e.message })); }
  }
  if (p === '/api/rc/delete' && req.method === 'POST') {
    const b = await readBody(req);
    const r = loadRc(b.p);
    if (!r || !b.e) return send(res, 400, '{"error":"bad args"}');
    try {
      const entries = zipReadEntries(fs.readFileSync(r.abs)).filter((x) => x.name !== b.e);
      fs.writeFileSync(r.abs, zipWriteEntries(entries));
      return send(res, 200, JSON.stringify({ ok: true }));
    } catch (e) { return send(res, 500, JSON.stringify({ error: e.message })); }
  }
  if (p === '/api/rc/export' && req.method === 'POST') {
    // {p, e, dir}：导出条目到指定目录
    const b = await readBody(req);
    const r = loadRc(b.p);
    if (!r || !b.e || !b.dir) return send(res, 400, '{"error":"bad args"}');
    try {
      const ent = zipReadEntries(fs.readFileSync(r.abs)).find((x) => x.name === b.e);
      if (!ent) return send(res, 404, '{"error":"not found"}');
      const base = path.basename(b.e.replace(/\\/g, '/'));
      fs.mkdirSync(b.dir, { recursive: true });
      const out = path.join(b.dir, base);
      fs.writeFileSync(out, ent.data);
      return send(res, 200, JSON.stringify({ ok: true, out }));
    } catch (e) { return send(res, 500, JSON.stringify({ error: e.message })); }
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

  // ---- 取色器三件套：裁剪模板 / 模板列表 / 图片查找 ----
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
