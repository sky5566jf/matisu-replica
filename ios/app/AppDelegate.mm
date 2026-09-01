#import "AppDelegate.h"
#import "ControlServer.h"
#import "MainVC.h"
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

// matisuauto://start | stop | restart | watchdog —— 供快捷指令 / PC 端远程触发
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
    }
    return YES;
}

@end
