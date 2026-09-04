// IDE 日志时间戳格式快速验证
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
  await pg.evaluate(() => { log('测试状态消息'); });
  await new Promise((r) => setTimeout(r, 300));
  const txt = await pg.evaluate(() => document.getElementById('logout').textContent);
  console.log('log 内容:', JSON.stringify(txt.trim()));
  const ok = /\[\d{2}:\d{2}:\d{2}\.\d{3}\] 测试状态消息/.test(txt);
  console.log(ok ? 'PASS: 毫秒时间戳格式正确' : 'FAIL: 格式不对');
  await b.close();
  process.exit(ok ? 0 : 1);
})();
