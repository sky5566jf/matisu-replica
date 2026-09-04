#import "MatisuHotspotManager.h"
#import "Watchdog.h"
#import <NetworkExtension/NetworkExtension.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <UIKit/UIKit.h>
#import <string.h>

// 重启自启唤醒源（对齐 MatisuTrollStore / TrollVNC 机制，2026-07-22 实机验证有效）：
// 重启手机 → 系统连 WiFi → NEHotspotHelper 回调 → 系统冷启动本 App → 拉起看门狗/守护进程
@interface MatisuHotspotManager ()
@property (nonatomic, assign) SCNetworkReachabilityRef reachability;
@property (nonatomic, assign) BOOL lastNetworkState;
@property (nonatomic, assign) BOOL registered;
@end

@implementation MatisuHotspotManager

+ (instancetype)sharedManager {
    static MatisuHotspotManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lastNetworkState = NO;
        _registered = NO;
        // App 切回前台时兜底确认服务在跑
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(appDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
    }
    return self;
}

#pragma mark - 对外入口

- (void)start {
    if (self.registered) return;
    self.registered = YES;
    [self registerHotspotHelper];
    [self startNetworkReachabilityMonitor];
}

#pragma mark - NEHotspotHelper 注册

- (void)registerHotspotHelper {
    // 注册 NEHotspotHelper：系统在 WiFi 关联/认证/保活时回调 handler。
    // 这是重启后冷启动 App 的唯一机制（纯巨魔版非越狱）。
    // 注意：注册失败（无权限/重复注册）只影响重启自启，不影响正常运行。
    NSDictionary *options = @{kNEHotspotHelperOptionDisplayName: @"MatisuAuto"};
    __weak typeof(self) weakSelf = self;
    BOOL result = [NEHotspotHelper registerWithOptions:options queue:dispatch_get_main_queue() handler:^(NEHotspotHelperCommand * _Nonnull cmd) {
        __strong typeof(self) strongSelf = weakSelf;
        [strongSelf handleCommand:cmd];
    }];

    NSLog(@"[MatisuAuto] NEHotspotHelper registered: %d", result);
}

#pragma mark - NEHotspotHelper 命令处理

- (void)handleCommand:(NEHotspotHelperCommand *)command {
    // 区分命令类型：Evaluate/Authenticate/Maintain 是 WiFi 关联类事件 → 拉起服务
    // FilterScanList/PresentUI/Logoff/None 仅应答不触发（避免高频事件重复拉起）
    BOOL shouldStartService = NO;

    switch (command.commandType) {
        case kNEHotspotHelperCommandTypeEvaluate:
        case kNEHotspotHelperCommandTypeAuthenticate:
        case kNEHotspotHelperCommandTypeMaintain:
            // 系统正在评估/认证/保活某个 WiFi 网络 → 网络子系统已活跃，拉起服务
            NSLog(@"[MatisuAuto] HotspotHelper command: %ld (association class)", (long)command.commandType);
            shouldStartService = YES;
            break;
        default:
            // 扫描列表/UI/注销等高频或无关事件：不触发
            break;
    }

    if (shouldStartService) {
        [self ensureServiceRunning];
    }
    // 不显式应答：iOS26 SDK 中 createResponse:/executeWithResponse: 选择器已不存在，
    // helper 注册本身即可在 WiFi 变化时触发拉起，保持与 TrollVNC v4.21 一致的行为
}

#pragma mark - 拉起服务

- (void)ensureServiceRunning {
    // 尊重"语义停止"：stopFlag 是落盘文件，重启后依然存在。
    // 用户主动停止过服务的话，HotspotHelper 唤醒不应清 flag 复活服务，
    // 等用户手动打开 app / matisuauto://start 再恢复。
    if (MatisuWatchdogIsStopped()) {
        NSLog(@"[MatisuAuto] service stopped by user, skip auto-start");
        return;
    }

    // 使用 beginBackgroundTask 延长后台执行时间
    // iOS 15+ 上 NEHotspotHelper 唤醒 app 后，如果没有 background task，
    // 系统可能会在看门狗/守护进程起来之前就杀死 app
    UIApplication *app = [UIApplication sharedApplication];
    __block UIBackgroundTaskIdentifier bgTaskId = [app beginBackgroundTaskWithExpirationHandler:^{
        [app endBackgroundTask:bgTaskId];
        bgTaskId = UIBackgroundTaskInvalid;
    }];

    NSLog(@"[MatisuAuto] ensureServiceRunning: starting watchdog+daemon");
    // 幂等：写 stopFlag 复位 + 确保看门狗在跑 + 18182 已监听则不重复拉起
    MatisuServiceStart();

    // 2 秒后再次确认（给看门狗拉起 daemon 的时间；若仍失败则补一次）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!MatisuPortInUse(18182)) MatisuServiceStart();
        if (bgTaskId != UIBackgroundTaskInvalid) {
            [app endBackgroundTask:bgTaskId];
            bgTaskId = UIBackgroundTaskInvalid;
        }
    });
}

#pragma mark - SCNetworkReachability 兜底监控

- (void)startNetworkReachabilityMonitor {
    // 监听任意网络连接变化（WiFi/以太网/蜂窝）
    // 修复纯以太网连接不触发 NEHotspotHelper 的问题（但只在 App 进程存活时有效）
    struct sockaddr_in zeroAddress;
    memset(&zeroAddress, 0, sizeof(zeroAddress));
    zeroAddress.sin_len = sizeof(zeroAddress);
    zeroAddress.sin_family = AF_INET;

    self.reachability = SCNetworkReachabilityCreateWithAddress(NULL, (const struct sockaddr *)&zeroAddress);

    if (self.reachability) {
        SCNetworkReachabilityContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
        SCNetworkReachabilitySetCallback(self.reachability, MatisuReachabilityCallback, &context);
        SCNetworkReachabilitySetDispatchQueue(self.reachability, dispatch_get_main_queue());

        // 检查初始状态
        SCNetworkReachabilityFlags flags;
        if (SCNetworkReachabilityGetFlags(self.reachability, &flags)) {
            BOOL initialConnected = (flags & kSCNetworkReachabilityFlagsReachable) != 0;
            self.lastNetworkState = initialConnected;
        }

        NSLog(@"[MatisuAuto] Network: reachability monitor started");
    }
}

static void MatisuReachabilityCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *info) {
    MatisuHotspotManager *manager = (__bridge MatisuHotspotManager *)info;

    BOOL isConnected = (flags & kSCNetworkReachabilityFlagsReachable) != 0;
    BOOL wasConnected = manager.lastNetworkState;
    manager.lastNetworkState = isConnected;

    if (isConnected && !wasConnected) {
        // 网络从无到有（WiFi 或以太网）→ 补拉起
        NSLog(@"[MatisuAuto] Network: connection detected, triggering service startup");
        [manager ensureServiceRunning];
    }
}

#pragma mark - 前台兜底

- (void)appDidBecomeActive:(NSNotification *)notification {
    // 前台兜底（stopFlag 语义由 ensureServiceRunning 内部尊重）
    [self ensureServiceRunning];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (self.reachability) {
        SCNetworkReachabilitySetCallback(self.reachability, NULL, NULL);
        SCNetworkReachabilitySetDispatchQueue(self.reachability, NULL);
        CFRelease(self.reachability);
        self.reachability = NULL;
    }
}

@end

// C 入口（供 AppDelegate 调用）
void MatisuHotspotManagerStart(void) {
    [MatisuHotspotManager.sharedManager start];
}
