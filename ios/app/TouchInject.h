#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// 触控注入 API（供 ControlServer / 后续 LuaJIT ffi 调用）
void MatisuTouchTap(float x, float y);
void MatisuTouchDown(int finger, float x, float y);
void MatisuTouchMove(int finger, float x, float y);
void MatisuTouchUp(int finger, float x, float y);
void MatisuTouchSwipe(float x1, float y1, float x2, float y2, double duration);

#ifdef __cplusplus
}
#endif
