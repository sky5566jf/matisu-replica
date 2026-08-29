#import "MatisuHID.h"
#import <mach/mach.h>
#import <unistd.h>

// ============================================================
// MatisuAuto iOS 触控注入实现（Phase 0）
// 方案：父 digitizer 事件(hand) + 子 digitizer 事件(finger)，
//       经 IOHIDEventSystemClient 分发。
// 坐标：屏幕点（points），与 PC 端 ios_client.py 下发一致。
// 注意：必须设置 SenderID，否则 iOS 会静默丢弃合成事件。
// ============================================================

#define MATISU_SENDER_ID 0xDEFACEDBEEFFECE5ULL

static IOHIDEventSystemClientRef MASystemClient() {
    static IOHIDEventSystemClientRef client = NULL;
    if (!client) {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    }
    return client;
}

// phase: 1=按下 2=移动 3=抬起
static void MASendFinger(int phase, int finger, float x, float y) {
    uint64_t t = mach_absolute_time();

    // 父事件（hand）
    IOHIDEventRef parent = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, t,
        kIOHIDDigitizerTransducerTypeHand, 0, 0, kIOHIDDigitizerEventTouch, 0,
        0, 0, 0, 0, 0, 0, true, 0);
    IOHIDEventSetIntegerValue(parent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);

    uint32_t eventMask;
    Boolean range = true, touch = true;
    if (phase == 1) {
        eventMask = kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventPosition;
    } else if (phase == 2) {
        eventMask = kIOHIDDigitizerEventPosition;
    } else { // up
        eventMask = kIOHIDDigitizerEventTouch;
        range = false; touch = false;
    }

    // 子事件（finger）
    IOHIDEventRef child = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, t,
        kIOHIDDigitizerTransducerTypeFinger, (uint32_t)(finger + 1), 2, eventMask,
        0, x, y, 0, 0, 0, range, touch, 0);
    IOHIDEventSetIntegerValue(child, kIOHIDEventFieldDigitizerType, kIOHIDDigitizerTransducerTypeFinger);
    IOHIDEventSetIntegerValue(child, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);

    IOHIDEventAppendEvent(parent, child);
    IOHIDEventSetSenderID(parent, MATISU_SENDER_ID);
    IOHIDEventSystemClientDispatchEvent(MASystemClient(), parent);

    CFRelease(child);
    CFRelease(parent);
}

void MatisuTouchTap(float x, float y) {
    MASendFinger(1, 0, x, y);
    usleep(16000);
    MASendFinger(3, 0, x, y);
}

void MatisuTouchDown(int finger, float x, float y) { MASendFinger(1, finger, x, y); }
void MatisuTouchMove(int finger, float x, float y) { MASendFinger(2, finger, x, y); }
void MatisuTouchUp(int finger, float x, float y)   { MASendFinger(3, finger, x, y); }

void MatisuTouchSwipe(float x1, float y1, float x2, float y2, double duration) {
    int steps = (int)(duration / 0.016) + 1;
    MASendFinger(1, 0, x1, y1);
    for (int i = 1; i <= steps; i++) {
        float t = (float)i / steps;
        MASendFinger(2, 0, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t);
    }
    MASendFinger(3, 0, x2, y2);
}
