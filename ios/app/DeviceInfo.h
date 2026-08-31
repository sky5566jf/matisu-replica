// MatisuAuto — iOS 设备信息采集
// 返回 UTF-8 JSON，字段命名对齐 PC 桥接层 device_bridge.js 的期望。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 采集当前设备信息，返回 UTF-8 编码的 JSON NSData；失败返回 nil。
#ifdef __cplusplus
extern "C" {
#endif

NSData* _Nullable MatisuDeviceInfoJSON(void);

/// 前台 App bundle id（SpringBoardServices 私有 API，取不到返空串）
NSString* _Nullable MatisuFrontApp(void);

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
