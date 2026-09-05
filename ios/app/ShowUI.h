// ShowUI.h — showUI 动态参数界面（WKWebView 渲染）
// 语义移植自原版 懒人精灵 showUI.lua（ts 风格），与 Android ShowUI.kt 逐段同构。
#ifndef SHOWUI_H
#define SHOWUI_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// 阻塞展示 UI 并返回 Lua 多值语义数组：
///   确认 → @[@"1", 值1, 值2, ...]；取消/超时/异常 → @[@"0"]
/// uitable 字段（键语义同 Android 版）：title/width/height/timer/config/cancelname/okname/button/views
NSArray<NSString *> *MatisuShowUIRun(NSDictionary *uitable);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
#endif // SHOWUI_H
