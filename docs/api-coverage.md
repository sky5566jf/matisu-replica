# MatisuAuto 复刻进度表（API manifest）
> 生成: 2026-09-01T22:48:19  ｜  PC 179 / iOS 99 / Android 17 已注册

## 触控（全局函数）（12 个）
**契约函数 133 个；覆盖率 PC 130/133 (97%) / iOS 63/133 (47%) / Android 17/133 (12%)**

> 注：仅统计 core.lua 契约函数（133 个）；文档长尾 ~570 个见 lua-api-surface.md §5。


| 函数 | PC | iOS | Android |
|---|---|---|---|
| tap | ✅ | ✅ | ✅ |
| longTap | ✅ | ✅ | ✅ |
| swipe | ✅ | ✅ | ✅ |
| touchDown | ✅ | ✅ | ✅ |
| touchMove | ✅ | ✅ | ✅ |
| touchMoveEx | ✅ | — | — |
| touchUp | ✅ | ✅ | ✅ |
| inputText | ✅ | ✅ | ✅ |
| keyPress | ✅ | ✅ | ✅ |
| keyDown | ✅ | ✅ | — |
| keyUp | ✅ | ✅ | — |
| setOnTouchListener | ✅ | — | — |

缺口: touchMoveEx, setOnTouchListener

## 图色与找图（全局函数，颜色 BBGGRR）（25 个）

| 函数 | PC | iOS | Android |
|---|---|---|---|
| findColor | ✅ | ✅ | ✅ |
| findColorT | ✅ | ✅ | — |
| findMultiColor | ✅ | ✅ | — |
| findMultiColorT | ✅ | ✅ | — |
| findMultiColorAll | ✅ | ✅ | — |
| findMultiColorAllT | ✅ | ✅ | — |
| cmpColor | ✅ | ✅ | ✅ |
| cmpColorEx | ✅ | ✅ | ✅ |
| cmpColorExT | ✅ | ✅ | — |
| getColorNum | ✅ | ✅ | ✅ |
| colorDiff | ✅ | ✅ | — |
| getPixelColor | ✅ | ✅ | ✅ |
| getScreenPixel | ✅ | ✅ | — |
| isDisplayDead | ✅ | ✅ | — |
| keepCapture | ✅ | ✅ | — |
| releaseCapture | ✅ | ✅ | — |
| setScreenScale | ✅ | ✅ | — |
| snapShot | ✅ | ✅ | ✅ |
| ocrText | ✅ | ✅ | — |
| findImage | ✅ | ✅ | — |
| findPic | ✅ | ✅ | — |
| findPicEx | ✅ | ✅ | — |
| findPicFast | ✅ | ✅ | — |
| findPicAllPoint | ✅ | ✅ | — |
| findCircle | ✅ | ✅ | — |

## 设备信息（全局函数）（26 个）

| 函数 | PC | iOS | Android |
|---|---|---|---|
| getCpuArch | ✅ | ✅ | — |
| getSdPath | ✅ | N/A | — |
| getDisplayDpi | ✅ | ✅ | — |
| getBatteryLevel | ✅ | ✅ | — |
| getDeviceId | ✅ | ✅ | — |
| getBrand | ✅ | N/A | — |
| getBootLoader | ✅ | N/A | — |
| getBoard | ✅ | N/A | — |
| getManufacturer | ✅ | N/A | — |
| getProduct | ✅ | N/A | — |
| getDevice | ✅ | N/A | — |
| getModel | ✅ | ✅ | — |
| getHardware | ✅ | N/A | — |
| getId | ✅ | N/A | — |
| getFingerprint | ✅ | N/A | — |
| getCpuAbi | ✅ | N/A | — |
| getCpuAbi2 | ✅ | N/A | — |
| getSdkVersion | ✅ | N/A | — |
| getOsVersionName | ✅ | ✅ | — |
| getWifiMac | ✅ | — | — |
| getDisplayInfo | ✅ | — | — |
| getDisplaySize | ✅ | ✅ | ✅ |
| getDisplayRotate | ✅ | — | — |
| getPackageName | ✅ | N/A | — |
| getSubscriberId | ✅ | N/A | — |
| getSimSerialNumber | ✅ | N/A | — |

缺口: getWifiMac, getDisplayInfo, getDisplayRotate

## 应用管理（全局函数）（15 个）

| 函数 | PC | iOS | Android |
|---|---|---|---|
| runApp | ✅ | ✅ | — |
| stopApp | ✅ | ✅ | — |
| getInstalledApk | ✅ | N/A | — |
| getInstalledApps | — | N/A | — |
| installApk | ✅ | N/A | — |
| getCurrentActivity | ✅ | N/A | — |
| frontAppName | ✅ | ✅ | — |
| appIsFront | ✅ | — | — |
| appIsRunning | ✅ | N/A | — |
| readPasteboard | ✅ | ✅ | — |
| writePasteboard | ✅ | ✅ | — |
| scanImage | — | N/A | — |
| sendSms | — | N/A | — |
| phoneCall | ✅ | N/A | — |
| runIntent | ✅ | N/A | — |

缺口: getInstalledApps, appIsFront, scanImage, sendSms

## 系统控制（全局函数）（17 个）

| 函数 | PC | iOS | Android |
|---|---|---|---|
| setControlBarPosNew | ✅ | N/A | — |
| showControlBar | ✅ | N/A | — |
| restartScript | ✅ | ✅ | — |
| vibrate | ✅ | ✅ | — |
| playAudio | ✅ | — | — |
| stopAudio | ✅ | — | — |
| rnd | ✅ | ✅ | — |
| exec | ✅ | N/A | — |
| sleep | ✅ | ✅ | ✅ |
| mSleep | ✅ | ✅ | ✅ |
| lockScreen | ✅ | ✅ | — |
| unLockScreen | ✅ | ✅ | — |
| setBTEnable | ✅ | N/A | — |
| setWifiEnable | ✅ | N/A | — |
| setAirplaneMode | ✅ | N/A | — |
| getRunEnvType | ✅ | — | — |
| exitScript | ✅ | ✅ | — |

缺口: playAudio, stopAudio, getRunEnvType

## 交互（全局函数 + ui 动态UI 模块表）（16 个）

| 函数 | PC | iOS | Android |
|---|---|---|---|
| toast | ✅ | — | — |
| hideToast | ✅ | — | — |
| showUI | ✅ | — | — |
| showUIEx | ✅ | — | — |
| createHUD | ✅ | — | — |
| showHUD | ✅ | — | — |
| hideHUD | ✅ | — | — |
| ui.newLayout | ✅ | — | — |
| ui.addButton | ✅ | — | — |
| ui.addEditText | ✅ | — | — |
| ui.addTextView | ✅ | — | — |
| ui.addCheckBox | ✅ | — | — |
| ui.addRadioBox | ✅ | — | — |
| ui.addComboBox | ✅ | — | — |
| ui.setOnClick | ✅ | — | — |
| ui.show | ✅ | — | — |

缺口: toast, hideToast, showUI, showUIEx, createHUD, showHUD, hideHUD, ui.newLayout, ui.addButton, ui.addEditText, ui.addTextView, ui.addCheckBox, ui.addRadioBox, ui.addComboBox, ui.setOnClick, ui.show

## 节点库 / 输入法 模块表（13 个）

| 函数 | PC | iOS | Android |
|---|---|---|---|
| nodeLib.getNodeXml | ✅ | — | — |
| nodeLib.saveNode | ✅ | — | — |
| nodeLib.saveNodeNew | ✅ | — | — |
| nodeLib.lockNode | ✅ | — | — |
| nodeLib.unlockNode | ✅ | — | — |
| nodeLib.openAccessibility | ✅ | — | — |
| nodeLib.closeAccessibility | ✅ | — | — |
| imeLib.lock | ✅ | — | — |
| imeLib.unlock | ✅ | — | — |
| imeLib.setText | ✅ | — | — |
| imeLib.deleteChar | ✅ | — | — |
| imeLib.finishInput | ✅ | — | — |
| imeLib.keyEvent | ✅ | — | — |

缺口: nodeLib.getNodeXml, nodeLib.saveNode, nodeLib.saveNodeNew, nodeLib.lockNode, nodeLib.unlockNode, nodeLib.openAccessibility, nodeLib.closeAccessibility, imeLib.lock, imeLib.unlock, imeLib.setText, imeLib.deleteChar, imeLib.finishInput, imeLib.keyEvent

## 加解密 / 网络 / JSON 模块表（标准扩展库）（9 个）

| 函数 | PC | iOS | Android |
|---|---|---|---|
| cipher.md5 | ✅ | ✅ | — |
| cipher.sha1 | ✅ | ✅ | — |
| cipher.base64 | ✅ | ✅ | — |
| cipher.aes | ✅ | — | — |
| network.httpGet | ✅ | ✅ | — |
| network.httpPost | ✅ | ✅ | — |
| network.download | ✅ | ✅ | — |
| json.encode | ✅ | ✅ | — |
| json.decode | ✅ | ✅ | — |

缺口: cipher.aes

