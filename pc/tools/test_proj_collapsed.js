// 启动时左侧项目管理默认全部折叠验证
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
  await p.waitForSelector('#filelist .phead', { timeout: 8000 }).catch(() => {});
  const r1 = await p.evaluate(() => ({
    blocks: document.querySelectorAll('#filelist .pblock').length,
    openArrs: [...document.querySelectorAll('#filelist .phead .arr')].filter((x) => x.textContent === '▼').length,
    trees: document.querySelectorAll('#filelist .ptree').length,
  }));
  console.log('启动态 ' + JSON.stringify(r1));
  // 点击第一个项目头 → 应展开
  await p.click('#filelist .phead');
  await new Promise((r) => setTimeout(r, 500));
  const r2 = await p.evaluate(() => ({
    openArrs: [...document.querySelectorAll('#filelist .phead .arr')].filter((x) => x.textContent === '▼').length,
    trees: document.querySelectorAll('#filelist .ptree, #filelist .pempty').length,
  }));
  console.log('点击后 ' + JSON.stringify(r2));
  const pass = r1.openArrs === 0 && r1.trees === 0 && r2.openArrs >= 1;
  console.log(pass ? 'PASS' : 'FAIL');
  await b.close();
  process.exit(pass ? 0 : 1);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
