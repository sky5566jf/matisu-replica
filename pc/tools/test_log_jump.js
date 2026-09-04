// 调试输出 [文件:行号] 点击跳转 + 链接化验证
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
  const pg = await b.newPage();
  await pg.goto('http://127.0.0.1:5586/', { waitUntil: 'networkidle2', timeout: 30000 });
  await new Promise((r) => setTimeout(r, 800));

  // 1) 注入模拟设备日志行
  await pg.evaluate(() => {
    $('btnClearLog').onclick();
    logAppend('[22:13:53.924] 开始运行脚本 _logtest.lua\n[22:13:53.927] [_logtest.lua:2] 你好，日志测试\n[22:13:53.935] 脚本停止运行\n[22:13:53.940] [错误] _logtest.lua:9: 模拟脚本错误');
  });
  const spans = await pg.evaluate(() => {
    const els = [...document.querySelectorAll('#logout .jref')];
    return els.map((s) => ({ f: s.dataset.f, l: s.dataset.l, text: s.textContent }));
  });
  console.log('链接化 span:', JSON.stringify(spans));
  const okSpans = spans.length === 2 && spans[0].f === '_logtest.lua' && spans[0].l === '2' && spans[1].l === '9';

  // 2) 先打开一个同名标签，点击 [..:2] 应切到该标签并定位第 2 行
  await pg.evaluate(() => {
    openTab('_logtest.lua', '第一行\n第二行\n第三行', { type: 'dev', name: '_logtest.lua' });
  });
  await pg.evaluate(() => {
    const sp = [...document.querySelectorAll('#logout .jref')].find((s) => s.dataset.l === '2');
    sp.click();
  });
  await new Promise((r) => setTimeout(r, 300));
  const state = await pg.evaluate(() => {
    const t = tabs[activeTab];
    let lineNo = 0;
    if (ED) lineNo = ED.view.state.doc.lineAt(ED.view.state.selection.main.from).number;
    return { tab: t && t.name, lineNo };
  });
  console.log('点击跳转后:', JSON.stringify(state));
  const okJump = state.tab === '_logtest.lua' && state.lineNo === 2;

  // 3) runActive 加速标志
  const okFlag = await pg.evaluate(() => typeof runActive === 'boolean' && runActive === false);

  console.log(okSpans ? 'PASS: 链接化' : 'FAIL: 链接化', '|', okJump ? 'PASS: 点击跳转' : 'FAIL: 点击跳转', '|', okFlag ? 'PASS: 轮询标志' : 'FAIL: 轮询标志');
  await b.close();
  process.exit(okSpans && okJump && okFlag ? 0 : 1);
})();
