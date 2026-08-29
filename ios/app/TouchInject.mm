#import "TouchInject.h"
#import "MatisuHID.h"

// iOS 端 MatisuTouch ObjC 封装（实现见 TouchInject.h），
// 实际触控逻辑在 ios/src/MatisuTouch.m（与 tweak 共用）。

@implementation MatisuTouch
+ (void)tapX:(float)x y:(float)y { MatisuTouchTap(x, y); }
+ (void)swipeX1:(float)x1 y1:(float)y1 x2:(float)x2 y2:(float)y2 duration:(double)d { MatisuTouchSwipe(x1, y1, x2, y2, d); }
+ (void)down:(int)finger x:(float)x y:(float)y { MatisuTouchDown(finger, x, y); }
+ (void)move:(int)finger x:(float)x y:(float)y { MatisuTouchMove(finger, x, y); }
+ (void)up:(int)finger x:(float)x y:(float)y   { MatisuTouchUp(finger, x, y); }
@end
