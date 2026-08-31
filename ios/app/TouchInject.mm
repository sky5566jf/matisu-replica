#import "TouchInject.h"
#import <UIKit/UIKit.h>
#import <unistd.h>
#import "sthid/STHIDEventGenerator.h"

// ============================================================
// MatisuAuto iOS 触控注入 —— STHID 桥接版
// 自研事件构造在真机 iOS 16 上静默无效（根因未查明），
// 改为直接复用 TrollVNC 已验证的 STHIDEventGenerator 实现。
// 坐标系：对外 API 收逻辑点（与 devinfo 报告的 width/height 同空间），
//         STHID 内部按物理像素归一化，这里负责 逻辑点 -> 物理像素 换算。
// ============================================================

int gOrientationFixQuad = 0;   // STHID 依赖的全局量（不修正方向）

static float gLogicalW = 320.0f;
static float gLogicalH = 568.0f;

void MatisuTouchSetScreenSize(float w, float h) {
    if (w > 0) gLogicalW = w;
    if (h > 0) gLogicalH = h;
}

// 当前物理像素尺寸（与 STHID 归一化基准一致）
static CGSize MAPixelSize(void) {
    if ([UIScreen instancesRespondToSelector:@selector(_unjailedReferenceBoundsInPixels)]) {
        CGSize px = [UIScreen mainScreen]._unjailedReferenceBoundsInPixels.size;
        if (px.width > 0 && px.height > 0) return px;
    }
    return [UIScreen mainScreen].nativeBounds.size;
}

static CGPoint MAToPixel(float x, float y) {
    CGSize px = MAPixelSize();
    return CGPointMake(x / gLogicalW * px.width, y / gLogicalH * px.height);
}

// 手指触点表（finger id 0..9 -> 像素坐标 + 是否按下）
#define MA_MAX_FINGERS 10
static CGPoint gPts[MA_MAX_FINGERS];
static BOOL gDown[MA_MAX_FINGERS] = {NO};

static STHIDEventGenerator *MAGen(void) {
    return [STHIDEventGenerator sharedGenerator];
}

extern "C" {

void MatisuTouchDown(int finger, float x, float y) {
    if (finger < 0 || finger >= MA_MAX_FINGERS) return;
    BOOL anyBefore = NO;
    for (int i = 0; i < MA_MAX_FINGERS; i++) anyBefore |= gDown[i];
    gPts[finger] = MAToPixel(x, y);
    gDown[finger] = YES;
    if (!anyBefore) {
        [MAGen() touchDownAtPoints:&gPts[finger] touchCount:1];
    } else {
        CGPoint act[MA_MAX_FINGERS]; int n = 0;
        for (int i = 0; i < MA_MAX_FINGERS; i++) if (gDown[i]) act[n++] = gPts[i];
        [MAGen() stUpdatePoints:act count:n];
    }
}

void MatisuTouchMove(int finger, float x, float y) {
    if (finger < 0 || finger >= MA_MAX_FINGERS || !gDown[finger]) return;
    gPts[finger] = MAToPixel(x, y);
    CGPoint act[MA_MAX_FINGERS]; int n = 0;
    for (int i = 0; i < MA_MAX_FINGERS; i++) if (gDown[i]) act[n++] = gPts[i];
    [MAGen() stUpdatePoints:act count:n];
}

void MatisuTouchUp(int finger, float x, float y) {
    if (finger < 0 || finger >= MA_MAX_FINGERS || !gDown[finger]) return;
    gPts[finger] = MAToPixel(x, y);
    CGPoint pt = gPts[finger];
    gDown[finger] = NO;
    [MAGen() liftUpAtPoints:&pt touchCount:1];
}

void MatisuTouchTap(float x, float y) {
    MatisuTouchDown(0, x, y);
    usleep(16000);
    MatisuTouchUp(0, x, y);
}

void MatisuTouchSwipe(float x1, float y1, float x2, float y2, double duration) {
    int steps = (int)(duration / 0.016) + 1;
    MatisuTouchDown(0, x1, y1);
    for (int i = 1; i <= steps; i++) {
        float t = (float)i / steps;
        MatisuTouchMove(0, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t);
        usleep(16000);
    }
    MatisuTouchUp(0, x2, y2);
}

} // extern "C"

@implementation MatisuTouch
+ (void)tapX:(float)x y:(float)y { MatisuTouchTap(x, y); }
+ (void)swipeX1:(float)x1 y1:(float)y1 x2:(float)x2 y2:(float)y2 duration:(double)d { MatisuTouchSwipe(x1, y1, x2, y2, d); }
+ (void)down:(int)finger x:(float)x y:(float)y { MatisuTouchDown(finger, x, y); }
+ (void)move:(int)finger x:(float)x y:(float)y { MatisuTouchMove(finger, x, y); }
+ (void)up:(int)finger x:(float)x y:(float)y   { MatisuTouchUp(finger, x, y); }
@end
