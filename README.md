# MatisuAuto —— 懒人精灵复刻工程（自研实现）

> 目标：用自研方式完整复刻「懒人精灵 / LuaRunner」自动化工具套件。
> 路线前提：**自研功能对等实现**，不逆向、不破解现有闭源产物（详见可行性分析报告）。

## Phase 0 验证结果

| 验证项 | 状态 | 说明 |
|--------|------|------|
| Lua 引擎加载执行 | ✅ | fengari (Lua 5.1 VM) 已成功加载并运行脚本 |
| 统一 API 契约调用 | ✅ | `core.lua` 定义的 `touch/device/color/node/ui` 被脚本正常调用 |
| 宿主函数桥接 | ✅ | PC 端将 JS 实现桥接为 Lua 全局 API（`runner.js` 已验证） |
| 安卓 AccessibilityService 骨架 | ✅ | APK 已装模拟器(192.69.0.18:5555)且无障碍服务已启用 |
| iOS 触控注入 tweak 骨架 | ✅ | .deb(rootless)+.tipa(TrollStore) 均 GitHub Actions 真编译并真机验证 |

## Phase 1 验证结果（PC 引擎桥接真实设备）

| 验证项 | 状态 | 说明 |
|--------|------|------|
| `touch.*` → 真实设备 | ✅ | `tap/swipe/doubleTap/longPress/touchDown·Move·Up` 经 iOS 18182 / Android adb 真下发 |
| `device.*` 真实 | ✅ | getScreenSize/getOSType/getDeviceName 真实；sleep 真实同步睡眠 |
| `network.*` 真实 | ✅ | httpGet/httpPost/download 走 `curl` 真 HTTP |
| `cipher.*` 真实 | ✅ | md5/sha1/base64 走 Node crypto |
| `json.*` 真实 | ✅ | fengari 表 <-> JS 对象互转 |
| `color.*` / `node.*` | 🟡 | 诚实桩（待 Phase 3 设备侧图色/UI 查询回传） |
| iOS 真机端到端 | ✅ | demo.lua 全流程下发后应用存活、无崩溃（IOKit 私有符号运行期解析成功） |
| Android 真机端到端 | ✅ | `MATISU_TARGET=android` 冒烟通过（adb input 下发） |

**已真跑验证**：`replica/pc/runner.js demo.lua` 在 iOS 真机(192.69.0.38)驱动全套触控，应用存活无崩溃；
切换 `MATISU_TARGET=android` 可在安卓模拟器(192.69.0.18:5555)同等驱动。

## 目录结构

```
replica/
├── common/lua-api/
│   └── core.lua              # ★ 三端共享的统一 Lua API 契约（接口"宪法"）
├── pc/
│   ├── runner.js            # PC 端 Lua 运行器（fengari，Phase 0 已验证）
│   ├── demo.lua             # 示例脚本
│   └── package.json
├── android/                 # 安卓 Runtime 骨架（AccessibilityService）
│   ├── app/src/main/java/com/matisu/auto/
│   │   ├── MainActivity.kt
│   │   └── AutoAccessibilityService.kt   # 触控/节点真实实现
│   ├── app/src/main/res/xml/accessibility_config.xml
│   ├── AndroidManifest.xml
│   └── build.gradle / settings.gradle
├── ios/tweak/               # iOS Runtime 骨架（Theos tweak，越狱用）
│   ├── Tweak.xm             # IOHIDEvent 触控注入 + MatisuTouch 封装
│   ├── Makefile
│   └── control
└── ios/app/                 # iOS Runtime 应用（Theos app → .tipa，TrollStore 可装）
    ├── Makefile / control / Info.plist / Entitlements.plist
    ├── main.mm / AppDelegate.*     # 极简 UIKit 应用
    ├── TouchInject.*              # MatisuTouch 触控注入（复用 tweak 方案）
    └── ControlServer.*            # 局域网 18182 控制服务（PC 下发 tap/swipe）
```

## 统一 API 契约（core.lua）

脚本层统一调用以下命名空间，三端各自用宿主语言实现：

- `touch`：tap / doubleTap / longPress / swipe / touchDown·Move·Up / inputText / key
- `device`：sleep / getScreenSize / getOSType / getDeviceName / getVersion / screenshot / vibrate / clipboard
- `color`：findColor / findColorEx / findImage / findMultiColor / ocr / getColor
- `node`：findNode / clickNode / getBounds / dump / waitNode
- `ui`：alert / toast / input / confirm / show
- `network`：httpGet / httpPost / download
- `cipher`：md5 / sha1 / base64 / aes
- `json`：encode / decode
- `console`：log / error

## 各端运行 / 编译

### PC（已验证 ✅）
```bash
cd replica/pc
# 默认目标 iOS（192.69.0.38:18182）；可经 devices.json 或环境变量切换目标
NODE_PATH=<fengari的node_modules> node runner.js                 # 跑 demo.lua（iOS）
MATISU_TARGET=android NODE_PATH=<fengari> node runner.js demo.lua # 切到 Android（adb）
# 例: NODE_PATH="C:/Users/Administrator/.workbuddy/binaries/node/workspace/node_modules" node runner.js
```
- `device_bridge.js`：触控/设备指令路由（iOS TCP ↔ Android adb），目标由 `devices.json` 的 `target` 决定，
  或被环境变量 `MATISU_TARGET`（ios|android）覆盖（优先级最高）。
- `network.*` 经系统 `C:/Windows/System32/curl.exe`；`cipher.*` 经 Node `crypto`；`json.*` 为 fengari 表<->JS 互转。

### 安卓（需 Android SDK）
用 Android Studio 打开 `replica/android`，Sync 后 `Build → Make`。
- `AutoAccessibilityService` 提供了 `tap/swipe/clickNode/dump` 等真实实现；
- 在 `MainActivity` 接入 `luaj` 加载 `core.lua` 并把服务方法桥接为 Lua 的 `touch.* / node.*` 即可运行脚本。
- 需用户在系统设置里手动开启无障碍服务。

### iOS（需 macOS + Theos + 越狱 SDK / TrollStore）
```bash
# A. 越狱 tweak（rootless / roothide）
cd replica/ios/tweak
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
make package install    # 需配置 THEOS_DEVICE_IP/PORT

# B. TrollStore 应用（.tipa，非越狱可装）
cd replica/ios/app
make package FINALPACKAGE=1          # 产出 .theos/obj/MatisuAuto.app
# 打包为 .tipa：
mkdir -p /tmp/tipa/Payload && cp -r .theos/obj/MatisuAuto.app /tmp/tipa/Payload/
cd /tmp/tipa && zip -r matisu-auto.tipa Payload
```
- `Tweak.xm` 与 `ios/app/TouchInject.mm` 共用 `MatisuTouch` 触控注入（IOHIDEvent digitizer）；
- `ios/app` 额外提供 `ControlServer`（端口 **18182**）：PC 用 `replica/pc/ios_client.py` 发 `tap 100 200` 即可驱动真机触控；
- 后续在 `%ctor`/`didFinishLaunching` 接入 LuaJIT，加载 `core.lua` 并 ffi 注册为 `touch.*`。

## 测试设备（已就绪，用于 Phase 0 真机验证）
- **安卓模拟器**：`192.69.0.18:5555`（已 root），`adb connect` 后 `install` 验证无障碍服务。
- **iOS 真机（TrollStore）**：`192.69.0.38`（iPhone SE2 / arm64e / iOS 16.1.1），SSH `mobile`/`12345678`。
  用 TrollStore 安装 `matisu-auto.tipa` 后，PC 端 `python pc/ios_client.py tap x y` 即可在真机触发触控。

## 后续路线（节选自可行性报告）

```
Phase 0 技术验证 ──✅──> Phase 1 安卓 MVP ──> Phase 2 PC IDE ──> Phase 3 iOS Runtime ──> Phase 4 完整生态
 (本阶段交付)         (6-8周)            (8-12周)           (10-14周)           (8-12周)
```

## 法律声明
本项目为功能对等的**自研实现**，不含对现有闭源软件的逆向、破解或授权绕过；
品牌名 `MatisuAuto` 为占位，可改为自有品牌。
