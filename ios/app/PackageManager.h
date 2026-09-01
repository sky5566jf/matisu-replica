// PackageManager.h — 脚本包（.lrj/.zip）安装与解包
//
// 运行模型（对齐懒人系数据区）：
//   installpkg → 包原样落 <root>/script/<name> → 清空 <root>/run/ → 解包进 run/
//   → run/资源/*.rc（也是 zip）二次解包到 资源/ 同级（原版行为：rc 里 res/x.png → 资源/res/x.png）
//   → run/entry.json 驱动启动（lc_entry），见 LuaEngine MatisuEntryScriptSource。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 把 zip 数据解包到 destDir（目录条目自动建目录；拒绝 ".." 与绝对路径条目）。
/// 返回写出的文件数，失败返回 -1。
int MatisuUnzipDataToDir(NSData *zipData, NSString *destDir);

/// 安装脚本包：name=纯文件名（如 demo.lrj），payload=zip 内容。
/// 成功返回 YES 且 outFiles 为解出的文件数；errMsg 带失败原因。
BOOL MatisuInstallPackage(NSString *name, NSData *payload, int *_Nullable outFiles, NSString *_Nullable *_Nullable errMsg);

NS_ASSUME_NONNULL_END
