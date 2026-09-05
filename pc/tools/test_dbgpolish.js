// 调试面板打磨验证：日志分类配色 + 运行耗时 + 变量行点击复制
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
  await p.goto('http://127.0.0.1:5586/', { waitUntil: 'load' });
  await p.waitForSelector('#btnRun2', { timeout: 8000 });

  // 1) 日志分类配色
  const cls = await p.evaluate(() => {
    log('[错误] main.lua:9: 模拟错误');        // IDE 错误行
    log('[10:00:00.000] 开始运行脚本 t.lua');  // 设备生命周期（透传格式带时间）
    log('[10:00:00.100] [t.lua:2] 普通 print');
    log('[10:00:01.000] 脚本停止运行');
    const rows = [...document.querySelectorAll('#logout span')];
    return {
      err: rows.some((x) => x.className === 'log-err' && x.textContent.includes('模拟错误')),
      life1: rows.some((x) => x.className === 'log-life' && x.textContent.includes('开始运行脚本')),
      life2: rows.some((x) => x.className === 'log-life' && x.textContent.includes('脚本停止运行')),
      normal: rows.some((x) => x.className === 'jref' && x.textContent.includes('t.lua:2')),
      errCount: rows.filter((x) => x.className === 'log-err').length,
    };
  });
  console.log('配色 ' + JSON.stringify(cls));
  // 2) 变量行点击复制反馈（headless 下 clipboard 可能失败，验证 fallback + 高亮类）
  await p.evaluate(() => renderVartable([['score', '38', 'number']]));
  await p.click('#varrows .vrow');
  await new Promise((r) => setTimeout(r, 100));
  const copied = await p.evaluate(() => document.querySelector('#varrows .vrow').classList.contains('vcopy'));
  console.log('变量行点击反馈=' + copied);
  const pass = cls.err && cls.life1 && cls.life2 && cls.normal && cls.errCount === 1 && copied;
  console.log(pass ? 'PASS' : 'FAIL');
  await b.close();
  process.exit(pass ? 0 : 1);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
