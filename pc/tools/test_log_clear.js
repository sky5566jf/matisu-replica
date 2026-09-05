// 运行前清空调试输出验证：logClear 清空 LOG_LINES/面板/搜索过滤；
// 并模拟 runCurrent 主路径（有活动标签时）确认先清空再记「开始发送脚本到设备」
const puppeteer = require('puppeteer-core');
const fs = require('fs');
function findChrome() {
  for (const p of [
    'C:/Program Files/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
    'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
  ]) if (fs.existsSync(p)) return p;
  throw new Error('no browser');
}
(async () => {
  const b = await puppeteer.launch({ executablePath: findChrome(), headless: 'new' });
  const p = await b.newPage();
  p.on('pageerror', (e) => console.error('PAGEERR', e.message));
  await p.goto('http://127.0.0.1:5586/', { waitUntil: 'load' });
  await p.waitForSelector('#btnRun2', { timeout: 8000 });
  await new Promise((r) => setTimeout(r, 600));

  // 1) logClear 基本行为：塞日志 + 搜索过滤 → 清空后全空
  const t1 = await p.evaluate(() => {
    log('AAA 旧日志1');
    log('BBB 旧日志2');
    document.getElementById('logsearch').value = 'AAA';
    renderLog();
    const before = document.getElementById('logout').textContent;
    logClear();
    return {
      lines: LOG_LINES.length,
      html: document.getElementById('logout').innerHTML,
      search: document.getElementById('logsearch').value,
      before,
    };
  });
  console.log('logClear: lines=' + t1.lines + ' htmlLen=' + t1.html.length + ' search="' + t1.search + '" (清空前面板含旧日志=' + (t1.before.length > 0) + ')');
  const ok1 = t1.lines === 0 && t1.html.length === 0 && t1.search === '' && t1.before.length > 0;

  // 2) runCurrent 主路径：打开一个标签并塞旧日志，stub fetch 让同步失败，
  //    面板应只剩本轮日志（旧日志先被清掉）
  const t2 = await p.evaluate(async () => {
    // 准备一个非 rc 的活动标签
    tabs.push({ name: '__t_logclear.lua', kind: 'lua', dirty: false, code: 'print(1)' });
    activeTab = tabs.length - 1;
    log('OLDLINE 上一轮残留');
    // stub fetch：/api/script 返回失败即可，清空点在其之前
    const origFetch = window.fetch;
    window.fetch = async (u) => ({ json: async () => ({ ok: false }) });
    try { await runCurrent(); } finally { window.fetch = origFetch; }
    // 还原标签
    tabs.splice(activeTab, 1); activeTab = -1;
    return {
      text: document.getElementById('logout').textContent,
      hasOld: LOG_LINES.some((l) => l.indexOf('OLDLINE') >= 0),
    };
  });
  console.log('runCurrent路径: hasOld=' + t2.hasOld + ' 本轮日志="' + t2.text.trim() + '"');
  const ok2 = !t2.hasOld && t2.text.indexOf('开始发送脚本到设备') >= 0 && t2.text.indexOf('[错误] 同步脚本到设备失败') >= 0;

  console.log(ok1 && ok2 ? 'PASS' : 'FAIL');
  await b.close();
  process.exit(ok1 && ok2 ? 0 : 1);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
