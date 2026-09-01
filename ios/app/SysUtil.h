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

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
