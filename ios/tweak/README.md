# MatisuAuto iOS Tweak（Phase 0 骨架）

基于 Theos 的触控注入 tweak，为复刻懒人精灵的 iOS Runtime 提供底层触控能力。

## 功能（Phase 0）
- `MatisuTouch` 封装：点击 / 滑动 / 多指 down·move·up
- 注入方案：IOHIDEvent digitizer 事件 + `IOHIDEventSystemClientDispatchEvent`
- 预留 LuaJIT 桥接点（`%ctor`，后续接 `common/lua-api/core.lua`）

## 编译前提（本机 Windows 无法编译，需在 macOS 环境）
1. 安装 [Theos](https://theos.dev)
2. 配置越狱 SDK 头文件（提供 `IOKit` 私有头，如 rpetrich/Carbonated）
3. 设置环境变量：`export THEOS=...`

## 打包形态
- **rootless**（默认，iOS 15+，/var/jb）：`make package`
- **rootful**（老设备）：`make package THEOS_PACKAGE_SCHEME=rootless` 关闭
- **TrollStore**：`make package`，再用 [azule](https://github.com/Al4ise/Azule) 注入 entitlements 转 .tipa

## 安装
```
make package && make install   # 需配置 THEOS_DEVICE_IP / PORT
```

## 验证
安装后在 iOS 端日志可见 `[MatisuAuto] Phase 0 tweak loaded`。
真实触控效果需在 Phase 3 接入 LuaJIT 与 PC 下发通道后联调。
