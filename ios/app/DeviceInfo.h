// MatisuAuto — iOS 设备信息采集
// 返回 UTF-8 JSON，字段命名对齐 PC 桥接层 device_bridge.js 的期望。
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// 采集当前设备信息，返回 UTF-8 编码的 JSON NSData；失败返回 nil。
#ifdef __cplusplus
extern "C" {
#endif

NSData* _Nullable MatisuDeviceInfoJSON(void);

/// 逻辑点屏幕尺寸：app 模式用 UIScreen.bounds（含方向），
/// headless daemon 下 bounds 返回 320x568 兼容默认值，
/// 此时用 nativeBounds/nativeScale 换算出原生逻辑点（竖向基准）。
CGSize MatisuLogicalScreenSize(void);

/// 前台 App bundle id（SpringBoardServices 私有 API，取不到返空串）
NSString* _Nullable MatisuFrontApp(void);

/// frontapp 诊断（供 diag 指令回传）
NSDictionary* _Nullable MatisuFrontAppDiag(void);

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
