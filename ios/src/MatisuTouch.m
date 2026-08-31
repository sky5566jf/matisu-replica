#import "MatisuHID.h"
#import <mach/mach.h>
#import <unistd.h>

// ============================================================
// MatisuAuto iOS 触控注入实现
// 方案：父 digitizer 事件(hand) + 子 finger 事件，经 IOHIDEventSystemClient 分发。
// 对齐可工作的 TrollVNC STHIDEventGenerator：
//   1) SenderID 必须用 0x8000000817319372（backboardd 认可的系统发送者），
//      自编 SenderID 会被静默丢弃；
//   2) digitizer 坐标为 0~1 归一化（相对显示屏），不能直接传逻辑点；
//   3) 父事件置 IsBuiltIn，子事件用 IOHIDEventCreateDigitizerFingerEvent
//      并补 minor/major radius。
// ============================================================

#define MATISU_SENDER_ID 0x8000000817319372ULL

// 归一化基准（逻辑点），由 MatisuTouchSetScreenSize 设置
static float gScreenW = 320.0f;
static float gScreenH = 568.0f;

void MatisuTouchSetScreenSize(float w, float h) {
    if (w > 0) gScreenW = w;
    if (h > 0) gScreenH = h;
}

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
    float nx = x / gScreenW;
    float ny = y / gScreenH;

    // 事件掩码（对齐 STHID：父子同 mask；down/lift=Touch|Identity，move=Position|Attribute）
    uint32_t mask;
    Boolean range = true, touch = true;
    if (phase == 1) {          // down
        mask = kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventIdentity;
    } else if (phase == 2) {   // move
        mask = kIOHIDDigitizerEventPosition | kIOHIDDigitizerEventAttribute;
    } else {                   // up
        mask = kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventIdentity;
        range = false; touch = false;
    }

    // 父事件（hand）
    IOHIDEventRef parent = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, t,
        kIOHIDDigitizerTransducerTypeHand, 0, 0, mask, 0,
        0, 0, 0, 0, 0, 0, touch, 0);
    IOHIDEventSetIntegerValue(parent, kIOHIDEventFieldIsBuiltIn, 1);
    IOHIDEventSetIntegerValue(parent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);

    // 子事件（finger）：identifier 从 2 起（SimulateTouch/STHID 惯例），归一化坐标
    uint32_t ident = (uint32_t)(finger + 2);
    IOHIDEventRef child = IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, t,
        ident, ident, mask,
        nx, ny, 0,
        0.0f,                  // tipPressure（STHID 默认 0）
        90.0f,                 // twist
        range, touch, 0);
    float radius = touch ? 5.0f : 0.0f;  // STHID defaultMajorRadius=5
    IOHIDEventSetFloatValue(child, kIOHIDEventFieldDigitizerMajorRadius, radius);
    IOHIDEventSetFloatValue(child, kIOHIDEventFieldDigitizerMinorRadius, radius);
    IOHIDEventSetIntegerValue(child, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);

    IOHIDEventAppendEvent(parent, child, 0);
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
