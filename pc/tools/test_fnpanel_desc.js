// 函数面板中文描述验证：分类渲染 + 描述非空 + strutils 分类 + 点击出帮助
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
  await p.waitForFunction(() => document.querySelectorAll('#fnlist .fnsec').length > 0, { timeout: 10000 });
  const info = await p.evaluate(() => {
    const secs = [...document.querySelectorAll('#fnlist .fnsec')].map((e) => e.textContent.trim());
    // 展开全部分类再统计
    document.querySelectorAll('#fnlist .fnsec').forEach((e) => e.classList.remove('collapsed'));
    document.querySelectorAll('#fnlist .fnsec').forEach((e) => { const a = e.querySelector('.farr'); if (a) a.textContent = '▼'; });
    const items = [...document.querySelectorAll('#fnlist .fnitem')];
    const withDesc = items.filter((e) => (e.querySelector('.fdesc') || {}).textContent || '').length;
    const sample = items.slice(0, 3).map((e) => e.textContent.trim().slice(0, 40));
    const fnNames = items.map((e) => e.dataset.f);
    return {
      secs,
      total: items.length,
      withDesc,
      sample,
      hasStrutils: secs.some((s) => s.includes('字符串处理')),
      hasFindPic: fnNames.includes('findPic') && fnNames.includes('findCircle'),
      hasT: fnNames.includes('findColorT') && fnNames.includes('cmpColorExT'),
    };
  });
  console.log('分类: ' + info.secs.join(' | '));
  console.log(`函数总数=${info.total} 带描述=${info.withDesc} 首行样例=${JSON.stringify(info.sample)}`);
  // 点一个函数看帮助面板
  await p.evaluate(() => {
    const el = [...document.querySelectorAll('#fnlist .fnitem')].find((e) => e.dataset.f === 'findMultiColor');
    if (el) el.onclick();
  });
  let help = { shown: false, head: '' };
  try {
    await p.waitForFunction(() => {
      const det = document.getElementById('hpdetail');
      const h = det && det.querySelector('h2');
      return h && h.textContent === 'findMultiColor';
    }, { timeout: 20000 });
    help = await p.evaluate(() => ({
      shown: !document.getElementById('helppanel').classList.contains('hidden'),
      head: (document.getElementById('hpdetail').querySelector('h2') || {}).textContent || '',
    }));
  } catch (_) {}
  const pass =
    info.total >= 95 && info.withDesc === info.total &&
    info.hasStrutils && info.hasFindPic && info.hasT &&
    help.shown && help.head === 'findMultiColor';
  console.log('帮助面板: shown=' + help.shown + ' head=' + help.head);
  console.log(pass ? 'PASS' : 'FAIL');
  await b.close();
  process.exit(pass ? 0 : 1);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
