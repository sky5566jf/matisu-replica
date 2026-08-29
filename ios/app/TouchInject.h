#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// 触控注入 C API（实现见 ios/src/MatisuTouch.m，与 tweak 共用）
void MatisuTouchTap(float x, float y);
void MatisuTouchDown(int finger, float x, float y);
void MatisuTouchMove(int finger, float x, float y);
void MatisuTouchUp(int finger, float x, float y);
void MatisuTouchSwipe(float x1, float y1, float x2, float y2, double duration);

#ifdef __cplusplus
}
#endif

// ObjC 封装（供 ControlServer / 后续 LuaJIT 调用）
@interface MatisuTouch : NSObject
+ (void)tapX:(float)x y:(float)y;
+ (void)swipeX1:(float)x1 y1:(float)y1 x2:(float)x2 y2:(float)y2 duration:(double)d;
+ (void)down:(int)finger x:(float)x y:(float)y;
+ (void)move:(int)finger x:(float)x y:(float)y;
+ (void)up:(int)finger x:(float)x y:(float)y;
@end
