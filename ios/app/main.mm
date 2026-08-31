#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "ControlServer.h"
#import "LuaEngine.h"
#include <string.h>
#include <unistd.h>

// 用法：
//   无参数            -> 正常 UIApplicationMain（TrollStore App，mobile 上下文）
//   --daemon          -> 无头守护模式（root）：不初始化 UIApplication，
//                        直接启动 18182 控制服务并常驻 runloop。
//                        与原版懒人精灵 RootWatchdog 以 root 运行的架构一致，
//                        AX 节点树 / CARenderServer 截图在 root 上下文才完整可用。
int main(int argc, char *argv[]) {
    @autoreleasepool {
        BOOL daemon = NO;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--daemon") == 0) { daemon = YES; break; }
        }
        if (daemon) {
            NSLog(@"[MatisuAuto] 守护模式启动（headless, uid=%d）", getuid());
            MatisuControlServerStart();
            MatisuLuaAutoRun();   // scripts/autorun.lua 存在则常驻执行
            CFRunLoopRun();
            return 0;
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
