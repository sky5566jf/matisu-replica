// MatisuAuto — 设备端图色查找（Phase 2）
// 直接在共享 IOSurface 上扫描，不做 PNG 编解码、不出进程。
// 颜色格式与原版/PC 桥一致：BBGGRR 整数或 "BBGGRR[-DRDGDB]" 串，| 分隔多色。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// 区域找色。命中返回 1 并写 outX/outY（逻辑点坐标），未命中返回 0。
int MatisuFindColor(int x1, int y1, int x2, int y2, NSString *colorSpec, int dir, double sim, int *outX, int *outY);

/// 多点比色（"x|y|color[-偏色],..."），全中返回 1。
int MatisuCmpColorEx(NSString *multiSpec, double sim);

/// 单点比色，返回 1/0。
int MatisuCmpColor(int x, int y, NSString *colorSpec, double sim);

/// 区域颜色计数。
int MatisuGetColorNum(int x1, int y1, int x2, int y2, NSString *colorSpec, double sim);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
