#import "AppDelegate.h"
#import "ControlServer.h"

@interface AppDelegate ()
@property (nonatomic, strong) UILabel *label;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor systemBackgroundColor];

    self.label = [[UILabel alloc] initWithFrame:vc.view.bounds];
    self.label.text = @"MatisuAuto\nTouch server @ :8182\n\n(Phase 0 骨架)";
    self.label.textAlignment = NSTextAlignmentCenter;
    self.label.numberOfLines = 0;
    [vc.view addSubview:self.label];

    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    // 启动局域网触控控制服务
    MatisuControlServerStart();
    return YES;
}

@end
