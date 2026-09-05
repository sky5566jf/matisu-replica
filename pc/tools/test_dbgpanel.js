// 调试面板完善验证：变量表渲染 + 日志工具条（复制/导出/自动滚动）
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
  p.on('dialog', async (d) => { await d.dismiss(); });   // 导出浏览器可能弹下载行为
  await p.goto('http://127.0.0.1:5586/', { waitUntil: 'load' });
  await p.waitForSelector('#btnRun2', { timeout: 8000 });

  // 1) 变量表：空态 hint
  let r = await p.evaluate(() => ({ hint: document.getElementById('varhint').style.display !== 'none', rows: document.querySelectorAll('#varrows .vrow').length }));
  console.log('空态 ' + JSON.stringify(r));
  // 2) 模拟引擎返回渲染
  await p.evaluate(() => {
    renderVartable([
      ['score', '38', 'number'],
      ['名字', '你好', 'string'],
      ['cfg', '<table>', 'table'],
      ['onTap', '<function>', 'function'],
      ['flag', 'true', 'boolean'],
      ['zzfn', '<function>', 'function'],
    ]);
  });
  const noFn = await p.evaluate(() => document.querySelectorAll('#varrows .vrow').length);
  await p.evaluate(() => { document.getElementById('varFns').checked = true; renderVartable(); });
  r = await p.evaluate(() => {
    const rows = [...document.querySelectorAll('#varrows .vrow')];
    return {
      hint: document.getElementById('varhint').style.display !== 'none',
      n: rows.length,
      first: rows[0]?.textContent.trim(),
      hasTico: !!document.querySelector('.vtico[data-t="table"]'),
    };
  });
  console.log('渲染(默认无函数) rows=' + noFn + ' ' + JSON.stringify(r));
  // 3) 日志工具条：自动滚动开关
  await p.evaluate(() => {
    for (let i = 0; i < 50; i++) log('行' + i);
  });
  const sc1 = await p.evaluate(() => {
    const el = document.getElementById('logout');
    return el.scrollTop + el.clientHeight >= el.scrollHeight - 4;   // 默认自动滚动贴底
  });
  await p.click('#logAuto');
  await p.evaluate(() => log('关滚动后新增一行'));
  const sc2 = await p.evaluate(() => {
    const el = document.getElementById('logout');
    return el.scrollTop + el.clientHeight < el.scrollHeight - 4;   // 关闭后不贴底
  });
  console.log('自动滚动 开=' + sc1 + ' 关=' + sc2);
  // 4) 复制按钮反馈
  await p.click('#btnCopyLog');
  await new Promise((x) => setTimeout(x, 300));
  const copyTxt = await p.evaluate(() => document.getElementById('btnCopyLog').textContent);
  console.log('复制按钮反馈=' + copyTxt);
  const pass = !r.hint && r.n === 6 && noFn === 4 && r.first.includes('flag') && r.hasTico && sc1 && sc2 && copyTxt === '已复制';
  console.log(pass ? 'PASS' : 'FAIL');
  await b.close();
  process.exit(pass ? 0 : 1);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
