#import "MatisuHID.h"
#import <UIKit/UIKit.h>

// ============================================================
// MatisuAuto iOS 触控注入 (Phase 0 tweak)
// 仅做注入能力预埋：MatisuTouch* API 见 ios/include/MatisuHID.h，
// 实现在 ios/src/MatisuTouch.m（tweak 与 app 共用）。
// 后续在 %ctor 接入 LuaJIT，加载 core.lua 并 ffi 注册为 touch.*，
// 监听来自 PC IDE 的脚本下发与执行指令。
// ============================================================

%ctor {
    NSLog(@"[MatisuAuto] Phase 0 tweak loaded (MatisuTouch ready)");
}
