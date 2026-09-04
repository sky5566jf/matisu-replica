// 调试面板按钮联动状态机验证
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
  await new Promise((r) => setTimeout(r, 600)); // 等 refreshState 初始回包
  const snap = () => p.evaluate(() => {
    const ids = ['btnRun2', 'btnStop2', 'btnDbg', 'btnEnc', 'btnStep', 'btnStepIn', 'btnCont'];
    const o = {};
    ids.forEach((id) => (o[id] = document.getElementById(id).disabled ? 0 : 1));
    return o;
  });
  const idle = await snap();
  console.log('空闲态 ' + JSON.stringify(idle));
  // 模拟运行态
  await p.evaluate(() => { runActive = true; updateDbgBtns(true); });
  const run = await snap();
  console.log('运行态 ' + JSON.stringify(run));
  // 恢复空闲
  await p.evaluate(() => { runActive = false; updateDbgBtns(false); });
  const idle2 = await snap();
  // 禁用态样式生效检查（停止按钮初始禁用，背景应为置灰 #3a414b）
  const stopBg = await p.evaluate(() => getComputedStyle(document.getElementById('btnStop2')).backgroundColor);
  console.log('恢复态 ' + JSON.stringify(idle2) + ' stopBg=' + stopBg);
  const pass =
    idle.btnRun2 === 1 && idle.btnStop2 === 0 && idle.btnDbg === 1 && idle.btnEnc === 0 && idle.btnStep === 0 && idle.btnStepIn === 0 && idle.btnCont === 0 &&
    run.btnRun2 === 0 && run.btnStop2 === 1 && run.btnDbg === 0 &&
    idle2.btnRun2 === 1 && idle2.btnStop2 === 0 &&
    stopBg === 'rgb(58, 65, 75)';
  console.log(pass ? 'PASS' : 'FAIL');
  await b.close();
  process.exit(pass ? 0 : 1);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
