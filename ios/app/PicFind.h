// MatisuAuto — 设备端找图（Phase 4）
// 模板 PNG 经 CoreGraphics 解码为 RGBA，匹配算法与 PC 桥 matchTemplate 同源
// （粗扫步进 + 9 点预筛 + 候选精修 + 非极大值抑制），一次 surface lock 完成。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// 区域找图。命中返回 1 并写 outX/outY（逻辑点坐标）。
/// picPath 为设备侧 PNG 路径（可用 snapShot 截取的模板）；sim 相似度 0~1。
int MatisuFindPic(int x1, int y1, int x2, int y2, NSString *picPath, double sim, int *outX, int *outY);

/// 透明找图：跳过模板 alpha<128 的像素。
int MatisuFindPicEx(int x1, int y1, int x2, int y2, NSString *picPath, double sim, int *outX, int *outY);

/// 区域截图 PNG（逻辑点区域；0,0,0,0=全屏），失败返回 nil。
NSData* _Nullable MatisuCapturePNGRegion(int x1, int y1, int x2, int y2);

/// 全部命中位置：返回逻辑点数组（成对 x,y），*outN 为点数，*outXY 由调用方 free。
/// 用 NMS（minDist=模板较大边一半）抑制相邻簇，最多 maxRet 个（0=不限）。
int MatisuFindPicAllPoint(int x1, int y1, int x2, int y2, NSString *picPath, double sim,
                          int maxRet, int * _Nonnull * _Nonnull outXY, int * _Nonnull outN);

/// 霍夫圆检测（OpenCV HoughCircles 同源）：在区域内找半径 [minR,maxR] 的圆。
/// dp=累加器降采样(1/2)，minDist=圆心最小间距，p1/p2=Canny 阈值。
/// 命中返回 1 并写 cx/cy/r（逻辑点+逻辑半径），否则 0。
int MatisuFindCircle(int x1, int y1, int x2, int y2,
                     int dp, int minDist, int p1, int p2, int minR, int maxR,
                     int *outCx, int *outCy, int *outR);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
