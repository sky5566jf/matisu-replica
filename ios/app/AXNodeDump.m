// MatisuAuto — iOS UI 节点树导出
//
// 关键实现说明：
//   iOS SDK 里【没有】ApplicationServices.framework（那是 macOS 的），
//   AXUIElement 这套 C API 位于私有 /System/Library/PrivateFrameworks/AXRuntime.framework。
//   因此这里不 #import 任何 AX 头文件，改为：
//     1) 自行声明所需的不透明类型与函数原型；
//     2) 运行时 dlopen(AXRuntime) + dlsym 取符号；
//     3) 任一符号缺失 / 无授权 → 直接返回 nil，由 PC 端降级为空节点列表，
//        不影响截图、图色、触控这些通道。
//
// 输出字段与 Android 侧 pub() 完全同构，PC 端 node_match 过滤逻辑得以原样复用。

#import "AXNodeDump.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>

#if !__has_feature(objc_arc)
#error "AXNodeDump.m must be compiled with ARC"
#endif

#pragma mark - AXRuntime 私有 API 的最小自声明

typedef CFTypeRef AXUIElementRef;
typedef CFTypeRef AXValueRef;
typedef int32_t   MAAXError;

enum { kMAAXErrorSuccess = 0 };
enum { kMAAXValueCGRectType = 3 };   // 与 macOS AXValueType 编号一致

typedef AXUIElementRef (*fn_SystemWide)(void);
typedef MAAXError (*fn_CopyAttr)(AXUIElementRef, CFStringRef, CFTypeRef *);
typedef MAAXError (*fn_CopyActions)(AXUIElementRef, CFArrayRef *);
typedef Boolean   (*fn_ValueGetValue)(AXValueRef, uint32_t, void *);
typedef CFTypeID  (*fn_ValueGetTypeID)(void);
typedef CFTypeID  (*fn_ElementGetTypeID)(void);
typedef void      (*fn_SetAXEnabled)(Boolean);

static struct {
    BOOL loaded;
    BOOL ok;
    fn_SystemWide       systemWide;
    fn_CopyAttr         copyAttr;
    fn_CopyActions      copyActions;
    fn_ValueGetValue    valueGetValue;
    fn_ValueGetTypeID   valueTypeID;
    fn_ElementGetTypeID elementTypeID;
} AX;

static void axLoad(void) {
    if (AX.loaded) return;
    AX.loaded = YES;

    void *h = dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_LAZY);
    if (!h) h = dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_LAZY);
    if (!h) {
        NSLog(@"[MatisuAuto] AXRuntime 载入失败: %s", dlerror() ?: "unknown");
        return;
    }

    AX.systemWide    = (fn_SystemWide)dlsym(h, "AXUIElementCreateSystemWide");
    AX.copyAttr      = (fn_CopyAttr)dlsym(h, "AXUIElementCopyAttributeValue");
    AX.copyActions   = (fn_CopyActions)dlsym(h, "AXUIElementCopyActionNames");
    AX.valueGetValue = (fn_ValueGetValue)dlsym(h, "AXValueGetValue");
    AX.valueTypeID   = (fn_ValueGetTypeID)dlsym(h, "AXValueGetTypeID");
    AX.elementTypeID = (fn_ElementGetTypeID)dlsym(h, "AXUIElementGetTypeID");

    // 目标进程需已开启 accessibility 才会返回完整树；best-effort 打开系统开关
    void *acc = dlopen("/usr/lib/libAccessibility.dylib", RTLD_LAZY);
    if (acc) {
        fn_SetAXEnabled setEnabled = (fn_SetAXEnabled)dlsym(acc, "_AXSSetApplicationAccessibilityEnabled");
        if (setEnabled) setEnabled(true);
    }

    AX.ok = (AX.systemWide && AX.copyAttr);
    if (!AX.ok) NSLog(@"[MatisuAuto] AXRuntime 符号缺失，节点查询不可用");
}

#pragma mark - AX 取值小工具

static NSString *axStr(AXUIElementRef el, CFStringRef attr) {
    CFTypeRef v = NULL;
    if (!AX.copyAttr || AX.copyAttr(el, attr, &v) != kMAAXErrorSuccess || !v) return @"";
    NSString *s = nil;
    if (CFGetTypeID(v) == CFStringGetTypeID()) {
        s = (__bridge NSString *)v;
    } else if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        s = [(__bridge NSNumber *)v stringValue];
    }
    NSString *r = s ? [s copy] : @"";
    CFRelease(v);
    return r;
}

/// 依次尝试多个属性名，返回第一个非空值（iOS 各版本属性命名不完全一致）
static NSString *axStrAny(AXUIElementRef el, NSArray<NSString *> *attrs) {
    for (NSString *a in attrs) {
        NSString *v = axStr(el, (__bridge CFStringRef)a);
        if (v.length) return v;
    }
    return @"";
}

static BOOL axBool(AXUIElementRef el, CFStringRef attr, BOOL dflt) {
    CFTypeRef v = NULL;
    if (!AX.copyAttr || AX.copyAttr(el, attr, &v) != kMAAXErrorSuccess || !v) return dflt;
    BOOL b = dflt;
    if (CFGetTypeID(v) == CFBooleanGetTypeID())      b = CFBooleanGetValue((CFBooleanRef)v);
    else if (CFGetTypeID(v) == CFNumberGetTypeID())  b = [(__bridge NSNumber *)v boolValue];
    CFRelease(v);
    return b;
}

/// AXFrame 在不同系统版本上可能是 AXValue / NSValue / NSDictionary / NSString，全部兼容
static CGRect axFrame(AXUIElementRef el) {
    CGRect r = CGRectZero;
    CFTypeRef v = NULL;
    if (!AX.copyAttr || AX.copyAttr(el, CFSTR("AXFrame"), &v) != kMAAXErrorSuccess || !v) return r;

    CFTypeID tid = CFGetTypeID(v);
    if (AX.valueTypeID && AX.valueGetValue && tid == AX.valueTypeID()) {
        AX.valueGetValue((AXValueRef)v, kMAAXValueCGRectType, &r);
    } else {
        id obj = (__bridge id)v;
        if ([obj isKindOfClass:[NSValue class]]) {
            r = [(NSValue *)obj CGRectValue];
        } else if ([obj isKindOfClass:[NSString class]]) {
            r = CGRectFromString((NSString *)obj);
        } else if ([obj isKindOfClass:[NSDictionary class]]) {
            NSDictionary *d = obj;
            NSNumber *x = d[@"X"] ?: d[@"x"];
            NSNumber *y = d[@"Y"] ?: d[@"y"];
            NSNumber *w = d[@"Width"] ?: d[@"width"] ?: d[@"w"];
            NSNumber *h = d[@"Height"] ?: d[@"height"] ?: d[@"h"];
            r = CGRectMake(x.doubleValue, y.doubleValue, w.doubleValue, h.doubleValue);
        }
    }
    CFRelease(v);
    return r;
}

static NSArray *axChildren(AXUIElementRef el) {
    CFTypeRef v = NULL;
    if (!AX.copyAttr || AX.copyAttr(el, CFSTR("AXChildren"), &v) != kMAAXErrorSuccess || !v) return @[];
    NSArray *r = (CFGetTypeID(v) == CFArrayGetTypeID()) ? [(__bridge NSArray *)v copy] : @[];
    CFRelease(v);
    return r;
}

static BOOL axHasAction(AXUIElementRef el, NSString *action) {
    if (!AX.copyActions) return NO;
    CFArrayRef names = NULL;
    if (AX.copyActions(el, &names) != kMAAXErrorSuccess || !names) return NO;
    BOOL found = NO;
    for (id n in (__bridge NSArray *)names) {
        if ([n isKindOfClass:[NSString class]] && [(NSString *)n isEqualToString:action]) { found = YES; break; }
    }
    CFRelease(names);
    return found;
}

/// 前台 App 的 bundle identifier（充当 Android 的 packageName，供 packageName(...) 过滤 / frontAppName()）
static NSString *elementBundleId(AXUIElementRef el) {
    if (!el || !AX.copyAttr) return @"";
    CFStringRef candidates[] = { CFSTR("AXBundleIdentifier"), CFSTR("AXBundleID"), NULL };
    for (int i = 0; candidates[i]; i++) {
        CFTypeRef v = NULL;
        if (AX.copyAttr(el, candidates[i], &v) == kMAAXErrorSuccess && v) {
            NSString *s = (CFGetTypeID(v) == CFStringGetTypeID())
                ? [(__bridge NSString *)v copy] : nil;
            CFRelease(v);
            if (s.length) return s;
        }
    }
    return @"";
}

#pragma mark - 角色语义推断（iOS 无 Android 那套显式布尔属性）

static BOOL roleClickable(NSString *role) {
    static NSSet *tap = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tap = [NSSet setWithObjects:@"Button", @"Cell", @"Link", @"MenuItem", @"Image", @"Icon",
               @"CheckBox", @"Switch", @"RadioButton", @"Tab", @"Incrementor", @"Decrementor",
               @"DisclosureTriangle", @"PopUpButton", @"SearchField", @"TextField", nil];
    });
    return [tap containsObject:role];
}

static BOOL checkableRole(NSString *role) {
    return ([role isEqualToString:@"CheckBox"] || [role isEqualToString:@"Switch"] ||
            [role isEqualToString:@"RadioButton"]);
}

static BOOL scrollableRole(NSString *role) {
    return ([role isEqualToString:@"ScrollView"] || [role isEqualToString:@"Table"] ||
            [role isEqualToString:@"CollectionView"] || [role isEqualToString:@"ScrollArea"]);
}

#pragma mark - 递归构建嵌套节点

static NSDictionary *buildNode(AXUIElementRef el, NSString *procName, int depth) {
    if (depth > 60) return nil;   // 防御异常深树

    NSString *role  = axStrAny(el, @[@"AXRole", @"AXRoleDescription", @"AXSubrole"]);
    NSString *label = axStrAny(el, @[@"AXLabel", @"AXTitle", @"AXName"]);
    NSString *value = axStrAny(el, @[@"AXValue"]);
    NSString *desc  = axStrAny(el, @[@"AXDescription", @"AXHelp", @"AXHint"]);
    NSString *ident = axStrAny(el, @[@"AXIdentifier", @"AXUniqueId"]);
    CGRect fr = axFrame(el);

    BOOL enabled  = axBool(el, CFSTR("AXEnabled"), YES);
    BOOL selected = axBool(el, CFSTR("AXSelected"), NO);
    BOOL focused  = axBool(el, CFSTR("AXFocused"), NO);
    BOOL checked  = NO;
    if (checkableRole(role)) checked = ([value isEqualToString:@"1"] || [value.lowercaseString isEqualToString:@"true"]);
    BOOL hasPress = axHasAction(el, @"AXPress");

    NSMutableArray *kids = [NSMutableArray array];
    for (id c in axChildren(el)) {
        CFTypeRef cf = (__bridge CFTypeRef)c;
        if (!cf) continue;
        if (AX.elementTypeID && CFGetTypeID(cf) != AX.elementTypeID()) continue;
        NSDictionary *k = buildNode((AXUIElementRef)cf, procName, depth + 1);
        if (k) [kids addObject:k];
    }

    NSMutableDictionary *n = [NSMutableDictionary dictionary];
    n[@"role"]      = role ?: @"";
    n[@"label"]     = label ?: @"";
    n[@"value"]     = value ?: @"";
    n[@"desc"]      = desc ?: @"";
    n[@"id"]        = ident ?: @"";
    n[@"frame"]     = @[@(fr.origin.x), @(fr.origin.y), @(fr.size.width), @(fr.size.height)];
    n[@"enabled"]   = @(enabled);
    n[@"hasPress"]  = @(hasPress);
    n[@"selected"]  = @(selected);
    n[@"focused"]   = @(focused);
    n[@"checked"]   = @(checked);
    n[@"children"]  = kids;
    n[@"procName"]  = procName ?: @"";
    return n;
}

#pragma mark - 展平为 Android 同构数组

static void dfs(NSDictionary *node, int parent, int depth, int index,
                NSMutableArray *out) {
    NSString *role  = node[@"role"];
    NSString *label = node[@"label"];
    NSString *value = node[@"value"];
    NSArray  *fr    = node[@"frame"];
    // 文本优先取 label，为空时退到 value（与 Android text 语义一致）
    NSString *text  = label.length ? label : value;

    int left   = (int)lround([fr[0] doubleValue]);
    int top    = (int)lround([fr[1] doubleValue]);
    int right  = left + (int)lround([fr[2] doubleValue]);
    int bottom = top  + (int)lround([fr[3] doubleValue]);

    BOOL clickable = [node[@"hasPress"] boolValue] || roleClickable(role);

    NSMutableDictionary *o = [NSMutableDictionary dictionary];
    int myIndex = (int)out.count;
    o[@"i"]            = @(myIndex);
    o[@"parent"]       = @(parent);
    o[@"depth"]        = @(depth);
    o[@"index"]        = @(index);
    o[@"drawingOrder"] = @(index);
    o[@"text"]         = text ?: @"";
    o[@"id"]           = node[@"id"] ?: @"";
    o[@"desc"]         = node[@"desc"] ?: @"";
    o[@"className"]    = role ?: @"";
    o[@"packageName"]  = node[@"procName"] ?: @"";
    o[@"left"]         = @(left);
    o[@"top"]          = @(top);
    o[@"right"]        = @(right);
    o[@"bottom"]       = @(bottom);
    o[@"cx"]           = @((left + right) / 2);
    o[@"cy"]           = @((top + bottom) / 2);
    NSArray *kids = node[@"children"] ?: @[];
    o[@"childCount"]     = @(kids.count);
    o[@"childs"]         = [NSMutableArray array];
    o[@"clickable"]      = @(clickable);
    o[@"longClickable"]  = @(clickable);
    o[@"scrollable"]     = @(scrollableRole(role));
    o[@"selected"]       = node[@"selected"] ?: @NO;
    o[@"enabled"]        = node[@"enabled"] ?: @YES;
    o[@"focusable"]      = @(clickable);
    o[@"focused"]        = node[@"focused"] ?: @NO;
    o[@"checkable"]      = @(checkableRole(role));
    o[@"checked"]        = node[@"checked"] ?: @NO;
    o[@"password"]       = @([role isEqualToString:@"SecureTextField"]);
    o[@"visibleToUser"]  = @((right > left) && (bottom > top));
    [out addObject:o];

    int ci = 0;
    for (NSDictionary *k in kids) {
        int childIdx = (int)out.count;
        [o[@"childs"] addObject:@(childIdx)];
        dfs(k, myIndex, depth + 1, ci++, out);
    }
}

#pragma mark - 入口

NSData* _Nullable MatisuDumpNodesJSON(void) {
    axLoad();
    if (!AX.ok) return nil;

    AXUIElementRef sys = AX.systemWide();
    if (!sys) { NSLog(@"[MatisuAuto] AXUIElementCreateSystemWide 返回空"); return nil; }

    // 优先取前台 App；取不到则退化到系统根
    AXUIElementRef app = NULL;
    AX.copyAttr(sys, CFSTR("AXFocusedApplication"), (CFTypeRef *)&app);
    AXUIElementRef root = app ? app : sys;

    NSDictionary *tree = buildNode(root, elementBundleId(root), 0);

    if (app) CFRelease(app);
    CFRelease(sys);

    if (!tree) return nil;

    NSMutableArray *flat = [NSMutableArray array];
    dfs(tree, -1, 0, 0, flat);

    NSError *err = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:flat options:0 error:&err];
    if (err) { NSLog(@"[MatisuAuto] uinode JSON 序列化失败: %@", err); return nil; }
    return d;
}
