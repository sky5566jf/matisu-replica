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

/// 同 MatisuLuaRun，chunkName 指定 chunk 名（runfile 传真实文件名，
/// 引擎日志/错误信息即带 [文件:行号] 定位）。
NSDictionary* _Nullable MatisuLuaRunNamed(NSString *source, NSString *chunkName);

// ---- 常驻脚本（单实例服务态）----
/// 后台线程启动常驻脚本；已在跑返回 NO（先 MatisuLuaStop）。
BOOL MatisuLuaStart(NSString *source);
/// 请求停止常驻脚本（hook 中断，luaL_error 抛出 "__MATISU_STOP__"）。
void MatisuLuaStop(void);
BOOL MatisuLuaRunning(void);
/// 取走常驻脚本累计 print 输出（线程安全，取后清空）。
NSString* _Nonnull MatisuLuaDrainOutput(void);
/// daemon 启动时调用：<数据区>/run/脚本/autorun.lua 存在则常驻执行。
void MatisuLuaAutoRun(void);

/// 启动入口脚本源码：run/entry.json 的 lc_entry 优先，退化 run/脚本/autorun.lua；都没有返回 nil。
NSString* _Nullable MatisuEntryScriptSource(void);

/// 脚本根目录（= MatisuRunScriptsDir()，mobile 可写）
NSString* _Nonnull MatisuScriptDir(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
