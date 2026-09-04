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
  const r = await p.evaluate(() => ({
    tab: document.querySelector('.rtab.active')?.dataset.t,
    page: document.querySelector('.rpage.active')?.id,
    title: document.getElementById('rpheadtitle')?.textContent,
    nRtab: document.querySelectorAll('.rtab').length,
    url: location.href,
    hasRtabs: !!document.getElementById('rtabs'),
  }));
  console.log('RESULT ' + JSON.stringify(r));
  await b.close();
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
