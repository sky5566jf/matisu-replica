// cdp_editor_test.js — 用 CDP 驱动 headless Chrome 实测 IDE 编辑器：点击、输入 findC、验证补全弹层
// 用法：node cdp_editor_test.js <ide_port>
const { spawn, execSync } = require('child_process');
const os = require('os');

const IDE_PORT = process.argv[2] || '5599';
const DBG_PORT = '9333';
const CHROME = 'C:/Program Files/Google/Chrome/Application/chrome.exe';

function httpJson(url) {
  return JSON.parse(execSync(`curl -s ${url}`).toString());
}
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

class Cdp {
  constructor(ws) { this.ws = ws; this.id = 0; this.pending = new Map(); this.events = [];
    ws.onmessage = (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id !== undefined && this.pending.has(msg.id)) {
        const p = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) p.rej(new Error(msg.error.message)); else p.res(msg.result);
      }
    };
  }
  static async connect(url) {
    const ws = new WebSocket(url);
    await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error('cdp ws fail')); });
    return new Cdp(ws);
  }
  send(method, params = {}) {
    return new Promise((res, rej) => {
      const id = ++this.id;
      this.pending.set(id, { res, rej });
      this.ws.send(JSON.stringify({ id, method, params }));
      setTimeout(() => { if (this.pending.has(id)) { this.pending.delete(id); rej(new Error('cdp timeout ' + method)); } }, 20000);
    });
  }
  async eval(expr) {
    const r = await this.send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error('eval 异常: ' + JSON.stringify(r.exceptionDetails.exception || {}));
    return r.result && r.result.value;
  }
  key(code, key, text) {
    return this.send('Input.dispatchKeyEvent', { type: text ? 'keyDown' : 'rawKeyDown', key, code, windowsVirtualKeyCode: code === 'KeyF' ? 70 : code === 'KeyI' ? 73 : code === 'KeyN' ? 78 : code === 'KeyD' ? 68 : code === 'KeyC' ? 67 : 0, text });
  }
}

(async () => {
  const chrome = spawn(CHROME, [
    '--headless=new', '--disable-gpu', '--no-first-run', '--user-data-dir=' + os.tmpdir() + '/cdp_' + Date.now(),
    `--remote-debugging-port=${DBG_PORT}`, 'about:blank',
  ], { stdio: 'ignore' });
  try {
    let targets;
    for (let i = 0; i < 20; i++) { await wait(500); try { targets = httpJson(`http://127.0.0.1:${DBG_PORT}/json`); if (targets.length) break; } catch (_) {} }
    const page = targets.find((t) => t.type === 'page');
    if (!page) throw new Error('没有 page target');
    const cdp = await Cdp.connect(page.webSocketDebuggerUrl);
    await cdp.send('Page.enable');
    await cdp.send('Runtime.enable');
    await cdp.send('Page.navigate', { url: `http://127.0.0.1:${IDE_PORT}/` });
    await wait(6000); // 等 LSP 连接 + meta 索引

    const mounted = await cdp.eval("!!document.querySelector('#cmhost .cm-editor') && document.querySelector('#code').style.display === 'none'");
    console.log(mounted ? 'PASS CodeMirror 已挂载（textarea 已隐藏）' : 'FAIL CodeMirror 未挂载');
    if (!mounted) process.exit(1);

    const lspOk = await cdp.eval("document.getElementById('stinfo').textContent");
    console.log('状态栏:', lspOk, lspOk.includes('LSP') ? '-> PASS' : '-> FAIL');
    if (!lspOk.includes('LSP')) process.exit(1);

    // 点击编辑器中央聚焦，然后输入 findC（先清空默认占位文档，避免打进注释上下文——注释里 LLS 只补文档内词）
    await cdp.eval("(function(){const v=ED.view;v.dispatch({changes:{from:0,to:v.state.doc.length,insert:''}});v.dispatch({selection:{anchor:0}});v.focus();})()");
    await wait(300);
    const box = await cdp.eval("(function(){const r=document.querySelector('.cm-content').getBoundingClientRect();return JSON.stringify({x:r.x+r.width/2,y:r.y+10});})()");
    const { x, y } = JSON.parse(box);
    await cdp.send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', clickCount: 1 });
    await cdp.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', clickCount: 1 });
    await wait(300);
    for (const [code, key, text] of [['KeyF', 'f', 'f'], ['KeyI', 'i', 'i'], ['KeyN', 'n', 'n'], ['KeyD', 'd', 'd'], ['KeyC', 'c', 'c']]) {
      await cdp.key(code, key, text);
      await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key, code });
      await wait(120);
    }
    await wait(2000); // 等补全弹层

    const tip = await cdp.eval("document.querySelector('.cm-tooltip-autocomplete') ? document.querySelector('.cm-tooltip-autocomplete').textContent : ''");
    console.log('补全弹层内容:', (tip || '(空)').slice(0, 200));
    // CM 补全列表是虚拟滚动渲染，textContent 只能看到前几条；断言出现任一 API 项即可
    if (!/find(Color|Circle|Pic|MultiColor)/.test(tip || '')) { console.log('FAIL: 弹层没有 API 补全项'); process.exit(1); }
    console.log('PASS 补全弹层包含 MatisuAuto API 项');

    // 截图存档
    const shot = await cdp.send('Page.captureScreenshot', { format: 'png' });
    require('fs').writeFileSync(__dirname + '/ide_editor_ui.png', Buffer.from(shot.data, 'base64'));
    console.log('截图已存 editor-build/ide_editor_ui.png');
    console.log('\n=== 浏览器实测 3/3 PASS ===');
    process.exit(0);
  } finally {
    try { chrome.kill(); } catch (_) {}
  }
})().catch((e) => { console.error('FAIL:', e.message); process.exit(1); });
