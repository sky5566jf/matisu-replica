// MatisuAuto — 设备端系统工具实现
#import "SysUtil.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <signal.h>
#import <sys/sysctl.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

// SpringBoardServices 私有类（运行期取类，免链接私有框架）
static Class maLSWorkspace(void) { return NSClassFromString(@"LSApplicationWorkspace"); }

NSString* _Nonnull MatisuReadPasteboard(void) {
    NSString *s = [UIPasteboard generalPasteboard].string;
    return s ?: @"";
}

void MatisuWritePasteboard(NSString *text) {
    [UIPasteboard generalPasteboard].string = text ?: @"";
}

BOOL MatisuOpenApp(NSString *bundleID) {
    Class cls = maLSWorkspace();
    if (!cls || !bundleID.length) return NO;
    id ws = [cls performSelector:@selector(defaultWorkspace)];
    if (!ws) return NO;
    SEL sel = @selector(openApplicationWithBundleID:);
    if (![ws respondsToSelector:sel]) return NO;
    BOOL ok = NO;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:[ws methodSignatureForSelector:sel]];
    inv.target = ws; inv.selector = sel;
    [inv setArgument:&bundleID atIndex:2];
    [inv invoke];
    [inv getReturnValue:&ok];
    return ok;
}

BOOL MatisuOpenURL(NSString *url) {
    Class cls = maLSWorkspace();
    if (!cls || !url.length) return NO;
    id ws = [cls performSelector:@selector(defaultWorkspace)];
    NSURL *u = [NSURL URLWithString:url];
    if (!ws || !u) return NO;
    SEL sel = @selector(openURL:);
    if (![ws respondsToSelector:sel]) return NO;
    BOOL ok = NO;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:[ws methodSignatureForSelector:sel]];
    inv.target = ws; inv.selector = sel;
    [inv setArgument:&u atIndex:2];
    [inv invoke];
    [inv getReturnValue:&ok];
    return ok;
}

#pragma mark - 进程查询 / 结束应用

/// 遍历进程表，收集所有 comm 等于 name 的 pid（MAXCOMLEN 截断到 15 字符）
static NSArray<NSNumber *> *maPidsForComm(NSString *name) {
    if (!name.length) return @[];
    const char *want = name.UTF8String;
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) < 0) return @[];
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(len);
    if (!procs) return @[];
    if (sysctl(mib, 4, procs, &len, NULL, 0) < 0) { free(procs); return @[]; }
    int count = (int)(len / sizeof(struct kinfo_proc));
    NSMutableArray *out = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        if (strcmp(procs[i].kp_proc.p_comm, want) == 0) {
            [out addObject:@(procs[i].kp_proc.p_pid)];
        }
    }
    free(procs);
    return out;
}

/// bundle id -> 可执行文件名（进程 comm）。拿不到返回 nil。
static NSString *maExecutableNameForBundle(NSString *bundleID) {
    Class proxyCls = NSClassFromString(@"LSApplicationProxy");
    if (!proxyCls) return nil;
    SEL sel = @selector(applicationProxyForIdentifier:);
    if (![proxyCls respondsToSelector:sel]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id proxy = [proxyCls performSelector:sel withObject:bundleID];
#pragma clang diagnostic pop
    if (!proxy) return nil;
    // bundleExecutable 是私有属性，用 KVC 取，避免直接声明导致的编译期依赖
    @try {
        id v = [proxy valueForKey:@"bundleExecutable"];
        if ([v isKindOfClass:[NSString class]] && [v length]) return v;
    } @catch (NSException *e) { /* 属性不存在 */ }
    return nil;
}

BOOL MatisuAppIsRunning(NSString *bundleID) {
    NSString *exe = maExecutableNameForBundle(bundleID);
    if (!exe.length) return NO;
    return maPidsForComm(exe).count > 0;
}

BOOL MatisuStopApp(NSString *bundleID) {
    if (!bundleID.length) return NO;
    NSString *exe = maExecutableNameForBundle(bundleID);
    if (!exe.length) {
        NSLog(@"[MatisuAuto] stopApp: 无法解析 %@ 的可执行名", bundleID);
        return NO;
    }
    NSArray *pids = maPidsForComm(exe);
    if (!pids.count) return NO;      // 本来就没在跑，视为已停止
    BOOL any = NO;
    for (NSNumber *p in pids) {
        pid_t pid = (pid_t)p.intValue;
        if (pid == getpid()) continue;
        if (kill(pid, SIGKILL) == 0) { any = YES; NSLog(@"[MatisuAuto] stopApp killed %d (%@)", pid, exe); }
    }
    return any;
}

#pragma mark - 锁屏 / 亮屏

/// SpringBoardServices 的符号走 dlsym：不链接私有框架，
/// 系统改名或权限不足时只是功能不可用，不会 dlopen 失败导致启动崩。
static void *maSBSHandle(void) {
    static void *h = NULL;
    static BOOL tried = NO;
    if (!tried) {
        tried = YES;
        h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
    }
    return h;
}

BOOL MatisuLockScreen(void) {
    void *h = maSBSHandle();
    if (!h) return NO;
    void (*lockFn)(void) = (void (*)(void))dlsym(h, "SBSLockDevice");
    if (!lockFn) return NO;
    lockFn();
    return YES;
}

BOOL MatisuUndimScreen(void) {
    void *h = maSBSHandle();
    if (!h) return NO;
    void (*undimFn)(void) = (void (*)(void))dlsym(h, "SBSUndimScreen");
    if (!undimFn) return NO;
    undimFn();
    return YES;
}
