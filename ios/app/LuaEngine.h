// MatisuAuto — 设备端 Lua 引擎（Phase 1）
// 在 daemon 进程内嵌 Lua 5.4，脚本直接调本进程触控/截图/键盘 C 函数，
// 不经 18182 socket（低延迟、可离线自主运行）。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// 执行 Lua 源码，返回字典：{@"ok": BOOL, @"output": NSString, @"error": NSString(仅失败时)}
/// 每次调用新建独立 lua_State（脚本间隔离）；print 输出收集进 output。
NSDictionary* _Nullable MatisuLuaRun(NSString *source);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
