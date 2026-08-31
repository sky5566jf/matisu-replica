#ifndef MATISU_HID_H
#define MATISU_HID_H

// ============================================================
// MatisuAuto iOS 触控注入 —— 自包含声明（不依赖任何私有头）
// 仅声明设备 IOKit.framework 中实际存在的符号，链接期用
// -Wl,-undefined,dynamic_lookup 放行，运行期在设备解析。
// 常量取自 IOHIDFamily 私有头，iOS 全版本稳定。
// ============================================================

#include <CoreFoundation/CoreFoundation.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef uint32_t IOHIDDigitizerTransducerType;
typedef uint32_t IOHIDDigitizerEventMask;
typedef uint32_t IOOptionBits;
typedef float IOHIDFloat;

// transducer 类型
#define kIOHIDDigitizerTransducerTypeHand   3
#define kIOHIDDigitizerTransducerTypeFinger 2

// digitizer event mask
#define kIOHIDDigitizerEventRange    0x00000001
#define kIOHIDDigitizerEventTouch    0x00000002
#define kIOHIDDigitizerEventPosition 0x00000004
#define kIOHIDDigitizerEventIdentity 0x00000008
#define kIOHIDDigitizerEventAttribute 0x00000010

// 顶层 IOHIDEventField（IOHIDEventFieldBase(type)=type<<16，kIOHIDEventTypeNULL=0）
#define kIOHIDEventFieldIsBuiltIn                   4

// IOHIDEventField（digitizer 基址 0xB0000）
#define kIOHIDEventFieldDigitizerX                  0xB0000
#define kIOHIDEventFieldDigitizerY                  0xB0001
#define kIOHIDEventFieldDigitizerType               0xB0004
#define kIOHIDEventFieldDigitizerIndex              0xB0005
#define kIOHIDEventFieldDigitizerIdentity           0xB0006
#define kIOHIDEventFieldDigitizerEventMask          0xB0007
#define kIOHIDEventFieldDigitizerRange              0xB0008
#define kIOHIDEventFieldDigitizerTouch              0xB0009
#define kIOHIDEventFieldDigitizerMajorRadius        0xB0014
#define kIOHIDEventFieldDigitizerMinorRadius        0xB0015
#define kIOHIDEventFieldDigitizerIsDisplayIntegrated 0xB0019

// 私有符号（运行时存在于设备的 IOKit.framework）
extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef allocator, uint64_t timeStamp,
    IOHIDDigitizerTransducerType type, uint32_t index, uint32_t identity,
    IOHIDDigitizerEventMask eventMask, uint32_t buttonMask,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat barrelPressure,
    Boolean range, Boolean touch, IOOptionBits options);
extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef allocator, uint64_t timeStamp,
    uint32_t index, uint32_t identity, IOHIDDigitizerEventMask eventMask,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat twist,
    Boolean range, Boolean touch, IOOptionBits options);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef event, uint32_t field, long long value);
extern void IOHIDEventSetFloatValue(IOHIDEventRef event, uint32_t field, IOHIDFloat value);
extern void IOHIDEventAppendEvent(IOHIDEventRef event, IOHIDEventRef childEvent, uint32_t options);
extern void IOHIDEventSetSenderID(IOHIDEventRef event, uint64_t senderID);
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);

// ---- 对外 C API（供 LuaJIT ffi / ObjC 封装调用）----
/// 设置触控坐标归一化基准（屏幕逻辑点尺寸）。digitizer HID 事件用 0~1 归一化坐标，
/// 必须由使用方（有 UIKit 上下文处）启动时设置；默认 320x568。
void MatisuTouchSetScreenSize(float w, float h);
void MatisuTouchTap(float x, float y);
void MatisuTouchDown(int finger, float x, float y);
void MatisuTouchMove(int finger, float x, float y);
void MatisuTouchUp(int finger, float x, float y);
void MatisuTouchSwipe(float x1, float y1, float x2, float y2, double duration);

#ifdef __cplusplus
}
#endif
#endif
