// MatisuPaths.h — 数据区路径中心（全工程唯一路径来源，禁止再硬编码 /var/mobile/...）
//
// 布局对齐懒人系 /var/mobile/Media/<bundle id>/ 数据区：
//   <root>/sys/         系统运行时资源（lua.zip、userinfo.json 等，预留）
//   <root>/ocr/         OCR 模型（det/rec/cls.onnx、keys.txt；ncnn 档预留）
//   <root>/script/      脚本包存放区（.lrj/.zip 原样落地，预留）
//   <root>/run/         当前工程运行区
//   <root>/run/脚本/     Lua 脚本（autorun.lua 在这）
//   <root>/run/界面/     .ui 布局文件（预留，showUI 用）
//   <root>/run/资源/     找图素材等（.rc 解包落点，预留）
//   <root>/run/插件/     插件（预留）
//   <root>/work/        脚本运行产物（截图、用户数据）
//   <root>/logdir/      日志（log.txt、ocr_debug.log、watchdog.log）
//   <root>/syspersist/  持久化（persist 授权等，预留）
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// 数据区根：/var/mobile/Media/<CFBundleIdentifier>（取不到 bundle id 时回退 com.matisu.auto）。
/// 懒创建；Media 下 mobile 直接可写，iTunes 文件共享可达。
NSString *MatisuDataRoot(void);

NSString *MatisuSysDir(void);         ///< <root>/sys
NSString *MatisuOcrDir(void);         ///< <root>/ocr
NSString *MatisuScriptPkgDir(void);   ///< <root>/script
NSString *MatisuRunDir(void);         ///< <root>/run
NSString *MatisuRunScriptsDir(void);  ///< <root>/run/脚本
NSString *MatisuRunUIDir(void);       ///< <root>/run/界面
NSString *MatisuRunResDir(void);      ///< <root>/run/资源
NSString *MatisuRunPluginDir(void);   ///< <root>/run/插件
NSString *MatisuWorkDir(void);        ///< <root>/work
NSString *MatisuLogDir(void);         ///< <root>/logdir
NSString *MatisuPersistDir(void);     ///< <root>/syspersist

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
