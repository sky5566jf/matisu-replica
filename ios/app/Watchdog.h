// MatisuAuto — 看门狗（TrollStore 无 LaunchDaemon 场景下的常驻保活）
//
// 设计来源：原版懒人精灵 RootWatchdog 的状态机（双 fork daemonize / PID 锁 /
// TCP 探活 / 启动期宽容 / 延迟重启二次确认 / 重启节流 / stopFlag 语义停止）。
//
// 实现取舍：不产出第二个 Mach-O，而是 exec 自身可执行文件并带 `--watchdog`，
// 这样看门狗天然继承 app 的 entitlements（无需另行签名），打包流程零改动。
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 若看门狗未在跑则后台拉起一个（幂等，靠 flock 去重）。应在 app 启动时调用。
void MatisuWatchdogEnsureStarted(void);

/// 语义停止：写 stopFlag，看门狗不再拉起。用户主动"停止服务"时调用。
void MatisuWatchdogStop(void);

/// 恢复保活：清 stopFlag 并确保看门狗在跑。用户"启动服务"时调用。
void MatisuWatchdogResume(void);

/// 看门狗是否处于"已停止（不拉起）"语义。
BOOL MatisuWatchdogIsStopped(void);

/// 状态快照（供 UI 显示）。字段：running/pid/restarts/lastRestartAt/
/// lastProbeOk/lastProbeAt/targetRunning/failStreak/port/runtimeDir/watchdogUptime
NSDictionary *MatisuWatchdogStatus(void);

/// 杀掉看门狗（下次 EnsureStarted 会重新拉起）。
void MatisuWatchdogKill(void);

/// 本机 TCP 端口是否已在监听（用于 GUI 判断是否已有守护进程顶着）。
BOOL MatisuPortInUse(int port);

/// 钉死运行时目录（守护进程由看门狗 spawn 时通过 --runtime 传入，
/// 保证 app / 看门狗 / 守护进程三者的状态文件落在同一处）。
void MatisuSetRuntimeDir(const char *dir);

/// 看门狗主体，由 main() 在 `--watchdog` 分支调用，永不返回。
/// argv: --watchdog <exePath> <runtimeDir> <port> [interval] [threshold] [delay] [minInterval] [uid]
int MatisuWatchdogRun(int argc, char *argv[]);

#ifdef __cplusplus
}
#endif
