// MatisuAuto — 设备端系统工具（剪贴板 / 应用启动 / URL 打开）
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// 读剪贴板文本（无内容返回 @""）
NSString* _Nonnull MatisuReadPasteboard(void);
void MatisuWritePasteboard(NSString *text);

/// 按 bundle id 拉起应用（LSApplicationWorkspace），成功 YES
BOOL MatisuOpenApp(NSString *bundleID);
/// 打开 URL（LSApplicationWorkspace openURL:）
BOOL MatisuOpenURL(NSString *url);

/// 按 bundle id 结束应用：查到可执行名后按进程名 SIGKILL，成功 YES。
/// 需要 root 或与目标同 uid；拿不到可执行名时返回 NO。
BOOL MatisuStopApp(NSString *bundleID);
/// 该 bundle id 的进程当前是否存在
BOOL MatisuAppIsRunning(NSString *bundleID);

/// 锁屏（SpringBoardServices 的 SBSLockDevice，运行时 dlsym 解析，找不到返回 NO）
BOOL MatisuLockScreen(void);
/// 点亮屏幕（SBSUndimScreen）——解锁流程第一步，亮屏后仍需脚本上滑
BOOL MatisuUndimScreen(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
