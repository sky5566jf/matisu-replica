#import <Foundation/Foundation.h>

/**
 MatisuAuto iOS UI 节点树导出
 ---------------------------
 用 AXUIElement 系统级无障碍 API 遍历「前台 App」的完整视图层级，
 输出与 Android 端 android_cap.py 的 pub() 完全一致字段名的 JSON 数组，
 使 PC 端 nodeQuery 的过滤逻辑（node_match）无需为 iOS 改写即可复用。

 需要 entitlement：com.apple.private.accessibility.inspection
 （TrollStore 应用加上该 entitlement 后即可跨 App 读取系统 UI 树）
 */
NSData* _Nullable MatisuDumpNodesJSON(void);
