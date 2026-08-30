// MatisuAuto — iOS 设备信息采集
// 返回 UTF-8 JSON，字段命名对齐 PC 桥接层 device_bridge.js 的期望。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 采集当前设备信息，返回 UTF-8 编码的 JSON NSData；失败返回 nil。
NSData* _Nullable MatisuDeviceInfoJSON(void);

NS_ASSUME_NONNULL_END
