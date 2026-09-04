// MatisuPaths.h — 数据区路径中心（全工程唯一路径来源，禁止再硬编码 /var/mobile/...）
//
// 布局对齐懒人系 /var/mobile/Media/<bundle id>/ 数据区：
//   <root>/ocr/         OCR 模型（det.onnx/rec.onnx/dict.txt；app 不再内置，装好后放这里）
//   <root>/work/        工作目录（默认创建；app 界面「工作目录」打开的就是它）
//   <root>/script/      脚本包存放区（.lrj/.zip 原样落地）
//   <root>/run/         当前工程运行区
//   <root>/run/脚本/     Lua 脚本（autorun.lua 在这）
//   <root>/run/资源/     找图素材等（.rc 解包落点）
//   <root>/logdir/      日志（log.txt、engine.log、ocr_debug.log）
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// 数据区根：/var/mobile/Media/<CFBundleIdentifier>（取不到 bundle id 时回退 com.matisu.auto）。
/// 懒创建；Media 下 mobile 直接可写，iTunes 文件共享可达。
NSString *MatisuDataRoot(void);

NSString *MatisuOcrDir(void);         ///< <root>/ocr（OCR 模型目录，默认创建）
NSString *MatisuWorkDir(void);        ///< <root>/work（默认创建，app 界面「工作目录」）
NSString *MatisuScriptPkgDir(void);   ///< <root>/script
NSString *MatisuRunDir(void);         ///< <root>/run
NSString *MatisuRunScriptsDir(void);  ///< <root>/run/脚本
NSString *MatisuRunResDir(void);      ///< <root>/run/资源
NSString *MatisuLogDir(void);         ///< <root>/logdir

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
