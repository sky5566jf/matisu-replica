#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <sys/types.h>
#include <mach/mach.h>
#include <IOKit/IOKitLib.h>
#include <CoreGraphics/CoreGraphics.h>

// ============================================================
// MatisuAuto iOS 触控注入 (Phase 0 骨架)
// 方案：IOHIDEvent digitizer 事件 + IOHIDEventSystemClient 分发
// 依赖：越狱 SDK 的 IOKit 私有头（如 rpetrich/Carbonated 或 Theos 自带）
// 适用：rootful / rootless / TrollStore（均需相应 entitlements）
//
// 注意：kIOHIDEvent* 常量与 IOHIDEventCreateDigitizerEvent 等符号来自
//       私有头，必须在越狱 SDK 环境下编译，本机(Windows)无法直接编译。
// ============================================================

#pragma mark - 触控注入核心

static IOHIDEventSystemClientRef MASystemClient() {
    static IOHIDEventSystemClientRef client = NULL;
    if (!client) {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    }
    return client;
}

// phase 约定：1=按下 2=移动 3=抬起（具体以 SDK 头中
// kIOHIDDigitizerEventTouch / ...Mask 常量为准）
static void MASendDigitizer(int phase, int index, float x, float y) {
    uint64_t abstime = 0; // 真实环境用 mach_absolute_time()
    IOHIDEventRef event = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, abstime,
        kIOHIDEventTypeDigitizer,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    );
    if (!event) return;

    IOHIDEventSetFloatValue(event, kIOHIDEventFieldDigitizerX, x);
    IOHIDEventSetFloatValue(event, kIOHIDEventFieldDigitizerY, y);
    IOHIDEventSetIntegerValue(event, kIOHIDEventFieldDigitizerTouch, 1);
    IOHIDEventSetIntegerValue(event, kIOHIDEventFieldDigitizerIndex, index);
    IOHIDEventSetIntegerValue(event, kIOHIDEventFieldDigitizerEventMask, phase);
    IOHIDEventSetIntegerValue(event, kIOHIDEventFieldDigitizerRange, 1);

    IOHIDEventSystemClientDispatchEvent(MASystemClient(), event);
    CFRelease(event);
}

static void MATap(float x, float y) {
    MASendDigitizer(1, 0, x, y);
    MASendDigitizer(3, 0, x, y);
}

static void MASwipe(float x1, float y1, float x2, float y2, double duration) {
    int steps = (int)(duration / 0.016) + 1;
    MASendDigitizer(1, 0, x1, y1);
    for (int i = 1; i <= steps; i++) {
        float t = (float)i / steps;
        MASendDigitizer(2, 0, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t);
    }
    MASendDigitizer(3, 0, x2, y2);
}

#pragma mark - ObjC 封装（供后续 LuaJIT ffi 直接调用）

@interface MatisuTouch : NSObject
+ (void)tapX:(float)x y:(float)y;
+ (void)swipeX1:(float)x1 y1:(float)y1 x2:(float)x2 y2:(float)y2 duration:(double)d;
+ (void)down:(int)finger x:(float)x y:(float)y;
+ (void)move:(int)finger x:(float)x y:(float)y;
+ (void)up:(int)finger x:(float)x y:(float)y;
@end

@implementation MatisuTouch
+ (void)tapX:(float)x y:(float)y { MATap(x, y); }
+ (void)swipeX1:(float)x1 y1:(float)y1 x2:(float)x2 y2:(float)y2 duration:(double)d { MASwipe(x1,y1,x2,y2,d); }
+ (void)down:(int)finger x:(float)x y:(float)y { MASendDigitizer(1, finger, x, y); }
+ (void)move:(int)finger x:(float)x y:(float)y { MASendDigitizer(2, finger, x, y); }
+ (void)up:(int)finger x:(float)x y:(float)y   { MASendDigitizer(3, finger, x, y); }
@end

#pragma mark - 入口（预留 LuaJIT 桥接点）

%ctor {
    NSLog(@"[MatisuAuto] Phase 0 tweak loaded");
    // TODO(Phase 3): 初始化 LuaJIT 引擎，加载 common/lua-api/core.lua，
    //   通过 ffi 将 MatisuTouch 的 C 函数注册为 Lua 的 touch.*，
    //   并监听来自 PC IDE（WDA / socket）的脚本下发与执行指令。
}
