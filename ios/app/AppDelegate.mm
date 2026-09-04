#import "AppDelegate.h"
#import "ControlServer.h"
#import "MainVC.h"
#import "MatisuPaths.h"
#import "Watchdog.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[MainVC alloc] init]];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];

    // 常驻保活：TrollStore 下没有 LaunchDaemon，靠看门狗在掉线后重新拉起守护进程
    MatisuWatchdogEnsureStarted();

    // 冷启动兜底：先给守护进程 2.5s 让路，若端口仍空闲再由 GUI 自己顶上，
    // 避免两个进程抢 18182（谁先 bind 谁服务，另一个被 watchdog 视为"已恢复"）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!MatisuPortInUse(18182)) MatisuControlServerStart();
    });
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    // 退后台前再确认一次，防止看门狗被 jetsam 回收后没人拉起
    MatisuWatchdogEnsureStarted();
}

// matisuauto://start | stop | restart | watchdog | workdir | logdir
// —— 供快捷指令 / PC 端远程触发，workdir/logdir 用于拉起 app 到指定页面
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary *)options {
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host isEqualToString:@"start"]) {
        MatisuWatchdogResume();
    } else if ([host isEqualToString:@"stop"]) {
        MatisuWatchdogStop();
    } else if ([host isEqualToString:@"restart"]) {
        MatisuWatchdogResume();
    } else if ([host isEqualToString:@"watchdog"]) {
        MatisuWatchdogEnsureStarted();
    } else if ([host isEqualToString:@"workdir"] || [host isEqualToString:@"logdir"]) {
        NSString *dir  = [host isEqualToString:@"workdir"] ? MatisuWorkDir() : MatisuLogDir();
        NSString *title = [host isEqualToString:@"workdir"] ? @"工作目录" : @"日志";
        UINavigationController *nav = (UINavigationController *)self.window.rootViewController;
        if (nav) {
            FileListVC *vc = [[FileListVC alloc] initWithDir:dir title:title];
            // 先回到主界面再 push：否则上次已经停在某个文件列表页时，
            // 栈顶不是 MainVC（旧写法直接 return），scheme 会被静默忽略。
            // 例如 PC 端先拉起 workdir 再拉 logdir，第二种情况不会生效。
            void (^go)(void) = ^{
                [nav popToRootViewControllerAnimated:NO];
                [nav pushViewController:vc animated:NO];
            };
            if (nav.presentedViewController) {
                // 有弹窗（如删除确认）时先收起，否则 push 后新页面被弹窗压住看不见
                [nav dismissViewControllerAnimated:NO completion:go];
            } else {
                go();
            }
        }
    }
    return YES;
}

@end
