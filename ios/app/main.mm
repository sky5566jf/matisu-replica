#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "ControlServer.h"
#import "LuaEngine.h"
#import "Watchdog.h"
#include <string.h>
#include <unistd.h>

// 用法：
//   无参数            -> 正常 UIApplicationMain（TrollStore App，mobile 上下文）
//   --watchdog <args> -> 看门狗进程（由 app exec 自身拉起）：纯后台、绝不触碰 UIKit，
//                        双 fork + setsid 后脱离父进程生命周期，探活 18182 并负责重新拉起
//   --daemon          -> 无头守护模式：不初始化 UIApplication，
//                        直接启动 18182 控制服务并常驻 runloop。
//                        与原版懒人精灵 RootWatchdog 以 root 运行的架构一致。
//                        可选 --runtime <dir> 钉死运行时目录（看门狗 spawn 时会带上）。
int main(int argc, char *argv[]) {
    @autoreleasepool {
        BOOL daemon = NO, watchdog = NO;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--watchdog") == 0) { watchdog = YES; break; }
            if (strcmp(argv[i], "--daemon") == 0) daemon = YES;
            // 运行时目录必须在做任何路径推导之前生效
            if (strcmp(argv[i], "--runtime") == 0 && i + 1 < argc) {
                MatisuSetRuntimeDir(argv[++i]);
            }
        }

        // 看门狗必须最先分流：它带自定义 argv，交给 UIApplicationMain 会被误解析
        if (watchdog) {
            return MatisuWatchdogRun(argc, argv);
        }

        if (daemon) {
            NSLog(@"[MatisuAuto] 守护模式启动（headless, uid=%d）", getuid());
            MatisuWatchdogEnsureStarted();   // 守护进程自己也要被看着
            MatisuControlServerStart();
            MatisuLuaAutoRun();   // scripts/autorun.lua 存在则常驻执行
            CFRunLoopRun();
            return 0;
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
