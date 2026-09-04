// MatisuAuto — NEHotspotHelper 重启自启管理器
//
// 核心机制（移植自 MatisuTrollStore 项目，源头为 TrollVNC TVNCHotspotManager）：
// - NEHotspotHelper 是纯巨魔版（非越狱）唯一系统级冷启动唤醒源
// - 设备重启后所有进程已死，只有系统 WiFi 关联事件能通过 HotspotHelper
//   注册把 App 拉起来（需 entitlements 里的 HotspotHelper 权限，已具备）
// - App 被唤醒 → handleCommand → beginBackgroundTask → MatisuServiceStart()
//   （清 stopFlag + 确保看门狗在跑 + 端口 18182 空闲才拉起 daemon，幂等）
//
// 与 MatisuTrollStore 的差异：本 app 已有 Watchdog 常驻体系，唤醒动作直接
// 调 Watchdog 的 MatisuServiceStart()，无需再 posix_spawn 独立 supervisor。
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 注册 NEHotspotHelper + SCNetworkReachability 兜底 + 前台兜底。
/// 在 app didFinishLaunching 里调用一次（幂等，重复调用直接返回）。
void MatisuHotspotManagerStart(void);

#ifdef __cplusplus
}
#endif
