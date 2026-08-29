#import "TouchInject.h"
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <unistd.h>
#import <IOKit/hid/IOHIDEvent.h>
#import <IOKit/hid/IOHIDEventSystemClient.h>

// ============================================================
// MatisuAuto iOS 触控注入 (Phase 0)
// 方案：IOHIDEvent digitizer 事件 + IOHIDEventSystemClient 分发
// 适用：TrollStore / rootless / rootful（需 platform-application 等 entitlements）
// 说明：kIOHIDEvent* 常量来自越狱/私有 SDK 头，必须在 Theos 环境下编译。
// ============================================================

static IOHIDEventSystemClientRef MASystemClient() {
    static IOHIDEventSystemClientRef client = NULL;
    if (!client) {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    }
    return client;
}

// phase 约定：1=按下 2=移动 3=抬起（对应 kIOHIDDigitizerEventTouch 等 mask）
static void MASendDigitizer(int phase, int finger, float x, float y) {
    uint64_t t = mach_absolute_time();

    // 父事件
    IOHIDEventRef parent = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, t,
        kIOHIDEventTypeDigitizer,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    if (!parent) return;

    // 子事件（手指）
    IOHIDEventRef child = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, t,
        kIOHIDEventTypeDigitizer,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    if (!child) { CFRelease(parent); return; }

    IOHIDEventSetIntegerValue(child, kIOHIDEventFieldDigitizerTouch, 1);
    IOHIDEventSetIntegerValue(child, kIOHIDEventFieldDigitizerIndex, finger);
    IOHIDEventSetIntegerValue(child, kIOHIDEventFieldDigitizerEventMask, phase);
    IOHIDEventSetFloatValue(child, kIOHIDEventFieldDigitizerX, x);
    IOHIDEventSetFloatValue(child, kIOHIDEventFieldDigitizerY, y);
    IOHIDEventSetIntegerValue(child, kIOHIDEventFieldDigitizerRange, 1);

    IOHIDEventAppendEvent(parent, child);
    IOHIDEventSystemClientDispatchEvent(MASystemClient(), parent);

    CFRelease(child);
    CFRelease(parent);
}

void MatisuTouchTap(float x, float y) {
    MASendDigitizer(1, 0, x, y);
    usleep(16000);
    MASendDigitizer(3, 0, x, y);
}

void MatisuTouchDown(int finger, float x, float y) { MASendDigitizer(1, finger, x, y); }
void MatisuTouchMove(int finger, float x, float y) { MASendDigitizer(2, finger, x, y); }
void MatisuTouchUp(int finger, float x, float y)   { MASendDigitizer(3, finger, x, y); }

void MatisuTouchSwipe(float x1, float y1, float x2, float y2, double duration) {
    int steps = (int)(duration / 0.016) + 1;
    MASendDigitizer(1, 0, x1, y1);
    for (int i = 1; i <= steps; i++) {
        float t = (float)i / steps;
        MASendDigitizer(2, 0, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t);
    }
    MASendDigitizer(3, 0, x2, y2);
}
