'use strict';
// 真机冒烟测试：device_bridge.js 真实 API 串联
process.env.MATISU_TARGET = 'android';
const B = require('./device_bridge.js');

function log(...a) { console.log(...a); }

(async () => {
  log('== 环境 ==');
  log('target =', B.CFG.target);
  log('hasRoot =', B.hasRoot());
  log('getRunEnvType =', B.getRunEnvType(), '(0=root/激活 1=无障碍)');
  log('getDisplaySize =', JSON.stringify(B.getDisplaySize()));
  log('getCpuArch =', B.getCpuArch(), '(0=x86 1=arm 2=arm64 3=x86_64)');
  log('getModel =', B.getModel());
  log('getSdkVersion =', B.getSdkVersion());
  log('getBatteryLevel =', B.getBatteryLevel());
  log('colorToRGB(0xaabbcc) =', JSON.stringify(B.colorToRGB(0xaabbcc)), '(应为 [204,187,170])');

  log('\n== 图色 ==');
  const gx = 200, gy = 360;
  const px = B.getPixelColor(gx, gy, 1);
  const pxh = B.getPixelColor(gx, gy, 0);
  log(`getPixelColor(${gx},${gy}) =`, px, '(' + pxh + ', BBGGRR)');
  const col = pxh;
  const fc = B.findColor(0, 0, 0, 0, col, 0, 0.9);
  log('findColor 全屏 同向色 ret,x,y =', JSON.stringify(fc));
  const gn = B.getColorNum(0, 0, 0, 0, col, 0.9);
  log('getColorNum 全屏 同色 =', gn);

  log('\n== 节点 ==');
  const nodes = B.nodeQuery([{ k: 'clickable', v: 'true', m: 'eq' }], 'all');
  log('clickable 节点数 =', Array.isArray(nodes) ? nodes.length : 'null');
  // 找一个有文字的节点做示范
  const txtNodes = B.nodeQuery([{ k: 'text', v: '', m: 'contains' }], 'all');
  log('含文字节点数 =', Array.isArray(txtNodes) ? txtNodes.length : 'null');
  if (Array.isArray(txtNodes) && txtNodes[0]) {
    const n = txtNodes[0];
    log('  sample.text =', n.text, 'bounds =', [n.left, n.top, n.right, n.bottom]);
  }

  log('\n== 触控（实际点击屏幕中央偏下安全区）==');
  const [sw, sh] = B.getDisplaySize();
  log('tap @', [sw >> 1, sh - 80]);
  B.tap(sw >> 1, sh - 80);
  log('longTap @', [40, 40]);
  B.longTap(40, 40, 600);
  log('swipe 400,200 -> 800,200');
  B.swipe(400, 200, 800, 200, 300);
  log('touchDown/Move/Up 多指模拟 id=0');
  B.touchDown(0, 300, 300); B.touchMove(0, 350, 350); B.touchUp(0);
  log('toast 测试');
  B.toast('MatisuAuto 桥接层冒烟 OK');

  log('\n== 全部通道通过 ==');
})().catch(e => { console.error('FATAL', e); process.exit(1); });
