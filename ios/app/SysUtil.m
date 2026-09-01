// MatisuAuto — 设备端系统工具实现
#import "SysUtil.h"
#import <UIKit/UIKit.h>

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
