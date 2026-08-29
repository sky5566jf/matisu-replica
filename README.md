# MatisuAuto —— 懒人精灵复刻工程（自研实现）

> 目标：用自研方式完整复刻「懒人精灵 / LuaRunner」自动化工具套件。
> 路线前提：**自研功能对等实现**，不逆向、不破解现有闭源产物（详见可行性分析报告）。

## Phase 0 验证结果

| 验证项 | 状态 | 说明 |
|--------|------|------|
| Lua 引擎加载执行 | ✅ | fengari (Lua 5.1 VM) 已成功加载并运行脚本 |
| 统一 API 契约调用 | ✅ | `core.lua` 定义的 `touch/device/color/node/ui` 被脚本正常调用 |
| 宿主函数桥接 | ✅ | PC 端将 JS 实现桥接为 Lua 全局 API（`runner.js` 已验证） |
| 安卓 AccessibilityService 骨架 | 🟡 | 代码完整，需 Android SDK 编译（本机无 SDK） |
| iOS 触控注入 tweak 骨架 | 🟡 | 代码完整，需 Theos + 越狱 SDK 编译（本机无 SDK） |

**已真跑验证**：`replica/pc/runner.js` 运行 `demo.lua`，输出符合预期（见下方运行记录）。

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
└── ios/tweak/               # iOS Runtime 骨架（Theos tweak）
    ├── Tweak.xm             # IOHIDEvent 触控注入 + MatisuTouch 封装
    ├── Makefile
    ├── control
    └── README.md
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
NODE_PATH=<fengari的node_modules> node runner.js
# 例: NODE_PATH="C:/Users/Administrator/.workbuddy/binaries/node/workspace/node_modules" node runner.js
```

### 安卓（需 Android SDK）
用 Android Studio 打开 `replica/android`，Sync 后 `Build → Make`。
- `AutoAccessibilityService` 提供了 `tap/swipe/clickNode/dump` 等真实实现；
- 在 `MainActivity` 接入 `luaj` 加载 `core.lua` 并把服务方法桥接为 Lua 的 `touch.* / node.*` 即可运行脚本。
- 需用户在系统设置里手动开启无障碍服务。

### iOS（需 macOS + Theos + 越狱 SDK）
```bash
cd replica/ios/tweak
make package            # rootless（iOS 15+ /var/jb）
make package install    # 需配置 THEOS_DEVICE_IP/PORT
```
- `Tweak.xm` 的 `MatisuTouch` 实现触控注入；
- 后续在 `%ctor` 接入 LuaJIT，加载 `core.lua` 并 ffi 注册为 `touch.*`。

## 后续路线（节选自可行性报告）

```
Phase 0 技术验证 ──✅──> Phase 1 安卓 MVP ──> Phase 2 PC IDE ──> Phase 3 iOS Runtime ──> Phase 4 完整生态
 (本阶段交付)         (6-8周)            (8-12周)           (10-14周)           (8-12周)
```

## 法律声明
本项目为功能对等的**自研实现**，不含对现有闭源软件的逆向、破解或授权绕过；
品牌名 `MatisuAuto` 为占位，可改为自有品牌。
