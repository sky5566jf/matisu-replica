#import "AppDelegate.h"
#import "ControlServer.h"
#import "MainVC.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[MainVC alloc] init]];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];

    // 启动局域网触控控制服务
    MatisuControlServerStart();
    return YES;
}

@end
