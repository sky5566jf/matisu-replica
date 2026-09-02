// MatisuAuto — iOS 设备信息采集实现
//
// 说明：
//   - 屏幕尺寸统一以「逻辑点（points）」为单位返回，与触控注入 / 节点坐标同一空间；
//     同时给出 scale 与像素尺寸，供 PC 端在需要时换算。
//   - UIKit 相关读取切回主线程，避免后台线程访问 UIScreen/UIApplication。
//   - 机型标识用 sysctlbyname("hw.machine")，如 iPhone9,3。

#import "DeviceInfo.h"
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <sys/types.h>
#import <sys/statvfs.h>
#import <sys/mount.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <string.h>
#import <dlfcn.h>

/// 机器标识 -> 友好机型名。未收录的机型原样回退显示标识（如 iPhone19,1），
/// 保证信息不丢失。表只需覆盖 Apple 公开过的 identifier。
static NSString *friendlyModelName(NSString *mid) {
    if (!mid.length) return @"";
    static NSDictionary *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"iPhone1,1": @"iPhone",              @"iPhone1,2": @"iPhone 3G",
            @"iPhone2,1": @"iPhone 3GS",
            @"iPhone3,1": @"iPhone 4",            @"iPhone3,2": @"iPhone 4",   @"iPhone3,3": @"iPhone 4",
            @"iPhone4,1": @"iPhone 4S",
            @"iPhone5,1": @"iPhone 5",            @"iPhone5,2": @"iPhone 5",
            @"iPhone5,3": @"iPhone 5c",           @"iPhone5,4": @"iPhone 5c",
            @"iPhone6,1": @"iPhone 5s",           @"iPhone6,2": @"iPhone 5s",
            @"iPhone7,1": @"iPhone 6 Plus",       @"iPhone7,2": @"iPhone 6",
            @"iPhone8,1": @"iPhone 6s",           @"iPhone8,2": @"iPhone 6s Plus",
            @"iPhone8,4": @"iPhone SE (第1代)",
            @"iPhone9,1": @"iPhone 7",            @"iPhone9,2": @"iPhone 7 Plus",
            @"iPhone9,3": @"iPhone 7",            @"iPhone9,4": @"iPhone 7 Plus",
            @"iPhone10,1": @"iPhone 8",           @"iPhone10,2": @"iPhone 8 Plus",
            @"iPhone10,3": @"iPhone X",           @"iPhone10,4": @"iPhone 8",
            @"iPhone10,5": @"iPhone 8 Plus",      @"iPhone10,6": @"iPhone X",
            @"iPhone11,2": @"iPhone XS",          @"iPhone11,4": @"iPhone XS Max",
            @"iPhone11,6": @"iPhone XS Max",      @"iPhone11,8": @"iPhone XR",
            @"iPhone12,1": @"iPhone 11",          @"iPhone12,3": @"iPhone 11 Pro",
            @"iPhone12,5": @"iPhone 11 Pro Max",  @"iPhone12,8": @"iPhone SE (第2代)",
            @"iPhone13,1": @"iPhone 12 mini",     @"iPhone13,2": @"iPhone 12",
            @"iPhone13,3": @"iPhone 12 Pro",      @"iPhone13,4": @"iPhone 12 Pro Max",
            @"iPhone14,2": @"iPhone 13 Pro",      @"iPhone14,3": @"iPhone 13 Pro Max",
            @"iPhone14,4": @"iPhone 13 mini",     @"iPhone14,5": @"iPhone 13",
            @"iPhone14,6": @"iPhone SE (第3代)",
            @"iPhone14,7": @"iPhone 14",          @"iPhone14,8": @"iPhone 14 Plus",
            @"iPhone15,2": @"iPhone 14 Pro",      @"iPhone15,3": @"iPhone 14 Pro Max",
            @"iPhone15,4": @"iPhone 15",          @"iPhone15,5": @"iPhone 15 Plus",
            @"iPhone16,1": @"iPhone 15 Pro",      @"iPhone16,2": @"iPhone 15 Pro Max",
            @"iPhone17,1": @"iPhone 16 Pro",      @"iPhone17,2": @"iPhone 16 Pro Max",
            @"iPhone17,3": @"iPhone 16",          @"iPhone17,4": @"iPhone 16 Plus",
            @"iPhone17,5": @"iPhone 16e",
            @"iPhone18,1": @"iPhone 17 Pro",      @"iPhone18,2": @"iPhone 17 Pro Max",
            @"iPhone18,3": @"iPhone 17",          @"iPhone18,4": @"iPhone Air",
            // iPad（常用机型）
            @"iPad6,11": @"iPad (第5代)",         @"iPad6,12": @"iPad (第5代)",
            @"iPad7,5":  @"iPad (第6代)",         @"iPad7,6":  @"iPad (第6代)",
            @"iPad7,11": @"iPad (第7代)",         @"iPad7,12": @"iPad (第7代)",
            @"iPad11,6": @"iPad (第8代)",         @"iPad11,7": @"iPad (第8代)",
            @"iPad12,1": @"iPad (第9代)",         @"iPad12,2": @"iPad (第9代)",
            @"iPad13,18":@"iPad (第10代)",        @"iPad13,19":@"iPad (第10代)",
            @"iPad4,1":  @"iPad Air",             @"iPad4,2":  @"iPad Air",
            @"iPad5,3":  @"iPad Air 2",           @"iPad5,4":  @"iPad Air 2",
            @"iPad11,3": @"iPad Air (第3代)",     @"iPad11,4": @"iPad Air (第3代)",
            @"iPad13,1": @"iPad Air (第4代)",     @"iPad13,2": @"iPad Air (第4代)",
            @"iPad13,16":@"iPad Air (第5代)",     @"iPad13,17":@"iPad Air (第5代)",
            @"iPad2,5":  @"iPad mini",            @"iPad2,6":  @"iPad mini",
            @"iPad4,4":  @"iPad mini 2",          @"iPad4,5":  @"iPad mini 2",
            @"iPad4,7":  @"iPad mini 3",          @"iPad4,8":  @"iPad mini 3",
            @"iPad5,1":  @"iPad mini 4",          @"iPad5,2":  @"iPad mini 4",
            @"iPad11,1": @"iPad mini (第5代)",    @"iPad11,2": @"iPad mini (第5代)",
            @"iPad14,1": @"iPad mini (第6代)",    @"iPad14,2": @"iPad mini (第6代)",
        };
    });
    NSString *r = map[mid];
    return r.length ? r : mid;
}

/// 本机局域网 IP：优先 Wi-Fi（en0），无 Wi-Fi 时退回蜂窝（pdp_ip*）
static NSString *localIP(void) {
    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) != 0) return @"";
    NSString *wifi = @"", *cell = @"";
    for (struct ifaddrs *p = ifa; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET) continue;
        char buf[INET_ADDRSTRLEN] = {0};
        if (!inet_ntop(AF_INET, &((struct sockaddr_in *)p->ifa_addr)->sin_addr, buf, sizeof(buf))) continue;
        NSString *ip = [NSString stringWithUTF8String:buf] ?: @"";
        if (!ip.length || [ip hasPrefix:@"127."]) continue;
        if (!strncmp(p->ifa_name, "en0", 3))            { if (!wifi.length) wifi = ip; }
        else if (!strncmp(p->ifa_name, "pdp_ip", 6))    { if (!cell.length) cell = ip; }
    }
    freeifaddrs(ifa);
    return wifi.length ? wifi : cell;
}

/// 数据分区容量。/var/mobile 是用户数据挂载点，最贴近"设置→通用→容量"语义；
/// 取不到时退回 / 。free 用 f_bavail（已排除系统保留空间），与系统显示一致。
static void storageBytes(unsigned long long *total, unsigned long long *freeBytes) {
    *total = 0; *freeBytes = 0;
    struct statvfs st;
    if (statvfs("/var/mobile", &st) != 0 && statvfs("/", &st) != 0) return;
    unsigned long long bs = st.f_frsize ? (unsigned long long)st.f_frsize : (unsigned long long)st.f_bsize;
    *total     = bs * (unsigned long long)st.f_blocks;
    *freeBytes = bs * (unsigned long long)st.f_bavail;
}

/// 用户在"设置→通用→关于本机"里设置的设备名（这台是 se2-2）。
///
/// iOS 16+ 起 UIDevice.name 对第三方 app 恒返回 "iPhone"（沙箱屏蔽），
/// 本 app 带 no-sandbox 权限，可直接读 SystemConfiguration 动态存储：
///   preferences.plist → Sets/<CurrentSet>/System/ComputerName
/// 拿不到时退回顶层 System/System/ComputerName、以及 HostNames 段。
static NSString *userDeviceName(void) {
    NSString *name = @"";
    NSData *d = [NSData dataWithContentsOfFile:@"/var/preferences/SystemConfiguration/preferences.plist"];
    id plist = d.length ? [NSPropertyListSerialization propertyListWithData:d options:0 format:NULL error:nil] : nil;
    if ([plist isKindOfClass:[NSDictionary class]]) {
        NSDictionary *root = (NSDictionary *)plist;
        // 候选 System 字典：优先当前生效的 Set，其次顶层 System
        NSMutableArray *cands = [NSMutableArray array];
        id sets = root[@"Sets"];
        id cur  = root[@"CurrentSet"];
        if ([sets isKindOfClass:[NSDictionary class]] && [cur isKindOfClass:[NSString class]]) {
            id set = ((NSDictionary *)sets)[cur];
            if ([set isKindOfClass:[NSDictionary class]]) {
                id sys = ((NSDictionary *)set)[@"System"];
                if ([sys isKindOfClass:[NSDictionary class]]) [cands addObject:sys];
            }
        }
        id sys0 = root[@"System"];
        if ([sys0 isKindOfClass:[NSDictionary class]]) {
            id sys = ((NSDictionary *)sys0)[@"System"];
            if ([sys isKindOfClass:[NSDictionary class]]) [cands addObject:sys];
            else                                          [cands addObject:sys0];
        }
        for (NSDictionary *s in cands) {
            for (NSString *k in @[@"ComputerName", @"HostName", @"LocalHostName"]) {
                id v = s[k];
                if ([v isKindOfClass:[NSString class]] && [v length]) { name = v; break; }
            }
            if (name.length) break;
        }
    }
    if (!name.length) name = [UIDevice currentDevice].name ?: @"";   // 兜底
    return name;
}

static NSString *machineId(void) {
    size_t len = 0;
    if (sysctlbyname("hw.machine", NULL, &len, NULL, 0) != 0 || len == 0) return @"";
    char *buf = (char *)malloc(len + 1);
    if (!buf) return @"";
    NSString *r = @"";
    if (sysctlbyname("hw.machine", buf, &len, NULL, 0) == 0) {
        buf[len] = 0;
        r = [NSString stringWithUTF8String:buf] ?: @"";
    }
    free(buf);
    return r;
}

static NSString *cpuArch(void) {
#if defined(__arm64e__)
    return @"arm64e";
#elif defined(__arm64__) || defined(__aarch64__)
    return @"arm64";
#elif defined(__arm__)
    return @"armv7";
#elif defined(__x86_64__)
    return @"x86_64";
#else
    return @"unknown";
#endif
}

/// 把 iOS 界面方向映射成与 Android getDisplayRotate 一致的 0/1/2/3（0°/90°/180°/270°）
static int rotateValue(void) {
    UIInterfaceOrientation o = UIInterfaceOrientationPortrait;
#if __IPHONE_OS_VERSION_MIN_REQUIRED < 130000
    o = [UIApplication sharedApplication].statusBarOrientation;
#else
    NSArray *scenes = nil;
    if (@available(iOS 13.0, *)) {
        scenes = [[UIApplication sharedApplication].connectedScenes allObjects];
        for (id s in scenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) {
                o = ((UIWindowScene *)s).interfaceOrientation;
                break;
            }
        }
    }
#endif
    switch (o) {
        case UIInterfaceOrientationPortrait:            return 0;
        case UIInterfaceOrientationLandscapeRight:      return 1;
        case UIInterfaceOrientationPortraitUpsideDown:  return 2;
        case UIInterfaceOrientationLandscapeLeft:       return 3;
        default:                                        return 0;
    }
}

static int batteryPercent(void) {
    UIDevice *d = [UIDevice currentDevice];
    if (!d.batteryMonitoringEnabled) d.batteryMonitoringEnabled = YES;
    float lv = d.batteryLevel;      // -1 表示未知
    if (lv < 0) return -1;
    int p = (int)lroundf(lv * 100.0f);
    if (p < 0) p = 0;
    if (p > 100) p = 100;
    return p;
}

NSData* _Nullable MatisuDeviceInfoJSON(void) {
    __block NSMutableDictionary *info = nil;

    void (^collect)(void) = ^{
        UIScreen *scr = [UIScreen mainScreen];
        CGRect b = scr.bounds;              // 逻辑点
        CGFloat scale = scr.scale;
        if (scale <= 0) scale = 1;
        CGRect nb = scr.nativeBounds;       // 像素（始终竖向基准）
        UIDevice *dev = [UIDevice currentDevice];
        NSString *mid = machineId();
        unsigned long long stTotal = 0, stFree = 0;
        storageBytes(&stTotal, &stFree);

        info = [NSMutableDictionary dictionary];
        info[@"name"]          = userDeviceName();
        info[@"model"]         = mid;
        info[@"modelFriendly"] = friendlyModelName(mid);
        info[@"modelName"]     = dev.model ?: @"";
        info[@"localIp"]       = localIP();
        info[@"storageTotal"]  = @(stTotal);
        info[@"storageFree"]   = @(stFree);
        info[@"systemName"]    = dev.systemName ?: @"iOS";
        info[@"systemVersion"] = dev.systemVersion ?: @"";
        info[@"sdk"]           = @([dev.systemVersion integerValue]);   // iOS 主版本号
        info[@"width"]         = @((int)lround(b.size.width));
        info[@"height"]        = @((int)lround(b.size.height));
        info[@"scale"]         = @((double)scale);
        info[@"pixelWidth"]    = @((int)lround(nb.size.width));
        info[@"pixelHeight"]   = @((int)lround(nb.size.height));
        info[@"dpi"]           = @((int)lround(scale * 163.0));         // iOS 基准 163ppi
        info[@"rotate"]        = @(rotateValue());
        info[@"battery"]       = @(batteryPercent());
        info[@"cpuAbi"]        = cpuArch();
        info[@"idfv"]          = dev.identifierForVendor.UUIDString ?: @"";
        info[@"bundleId"]      = [NSBundle mainBundle].bundleIdentifier ?: @"";
    };

    if ([NSThread isMainThread]) {
        collect();
    } else {
        dispatch_sync(dispatch_get_main_queue(), collect);
    }

    if (!info) return nil;
    NSError *err = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:info options:0 error:&err];
    if (err) {
        NSLog(@"[MatisuAuto] devinfo JSON 序列化失败: %@", err);
        return nil;
    }
    return d;
}

// 前台 App bundle id：FBSApplicationWorkspace（FrontBoardServices，daemon 上下文可靠，
// 与 TrollVNC frontmost 检测 Tier1 同款），SBS 符号式作兜底。
#import <objc/runtime.h>
#import <objc/message.h>

static NSMutableDictionary *gFADiag = nil;
static void faSet(NSString *k, id v) { if (!gFADiag) gFADiag = [NSMutableDictionary dictionary]; gFADiag[k] = v; }
NSDictionary* _Nullable MatisuFrontAppDiag(void) { return gFADiag ?: @{}; }

NSString* _Nullable MatisuFrontApp(void) {
    @try {
        static Class FBSWS = Nil;
        static BOOL probed = NO;
        if (!probed) {
            probed = YES;
            if (!NSClassFromString(@"FBSApplicationWorkspace"))
                dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
            FBSWS = NSClassFromString(@"FBSApplicationWorkspace");
            if (!FBSWS) FBSWS = NSClassFromString(@"FBApplicationWorkspace");
            if (!FBSWS) FBSWS = NSClassFromString(@"SBApplicationWorkspace");
            faSet(@"ws_class", FBSWS ? NSStringFromClass(FBSWS) : @"nil");
        }
        // Tier 0：FBProcessManager（RootCore 同源，frontmostApplication 属性）
        {
            static Class FBPM = Nil;
            if (!FBPM) {
                if (!NSClassFromString(@"FBProcessManager"))
                    dlopen("/System/Library/PrivateFrameworks/FrontBoard.framework/FrontBoard", RTLD_LAZY);
                FBPM = NSClassFromString(@"FBProcessManager");
                faSet(@"fbpm_class", FBPM ? @"ok" : @"nil");
            }
            if (FBPM && [FBPM respondsToSelector:NSSelectorFromString(@"sharedInstance")]) {
                id pm = ((id (*)(id, SEL))objc_msgSend)(FBPM, NSSelectorFromString(@"sharedInstance"));
                faSet(@"fbpm_nil", @(pm == nil));
                // frontmostApplication 属性在 iOS 16 已不存在；改为遍历进程找前台。
                // processes/allProcesses 多个候选选择器逐个探测
                NSArray *procs = nil;
                for (NSString *selName in @[@"processes", @"allProcesses"]) {
                    SEL s = NSSelectorFromString(selName);
                    faSet([@"fbpm_has_" stringByAppendingString:selName], @([pm respondsToSelector:s]));
                    if ([pm respondsToSelector:s]) {
                        id r = ((id (*)(id, SEL))objc_msgSend)(pm, s);
                        if ([r isKindOfClass:[NSArray class]] && [(NSArray *)r count] > 0) { procs = r; break; }
                        if ([r isKindOfClass:[NSDictionary class]]) procs = [(NSDictionary *)r allValues];
                        if ([r isKindOfClass:[NSSet class]]) procs = [(NSSet *)r allObjects];
                        if (procs.count) break;
                    }
                }
                if (procs) {
                    procs = [procs isKindOfClass:[NSArray class]] ? procs : nil;
                    faSet(@"fbpm_procs", @(procs ? (long)procs.count : -1L));
                    // 权限受限时 mobile 只能看到自己（procs<=1 即 daemon 自身），
                    // 此时下结论必错（会把自己报成前台）——跳过本层走下层。
                    if (procs.count <= 1) procs = nil;
                    for (id p in (procs ?: @[])) {
                        BOOL fg = NO;
                        for (NSString *selName in @[@"isForeground", @"foreground", @"isActive"]) {
                            SEL s = NSSelectorFromString(selName);
                            if ([p respondsToSelector:s]) {
                                fg = ((BOOL (*)(id, SEL))objc_msgSend)(p, s);
                                if (fg) { faSet(@"fbpm_fg_sel", selName); break; }
                            }
                        }
                        if (fg && [p respondsToSelector:@selector(bundleIdentifier)]) {
                            NSString *bid = ((NSString *(*)(id, SEL))objc_msgSend)(p, @selector(bundleIdentifier));
                            if (bid.length) return bid;
                        }
                    }
                    faSet(@"fbpm_fg_found", @NO);
                }
            }
        }
        if (FBSWS) {
            SEL dw = NSSelectorFromString(@"defaultWorkspace");
            if ([FBSWS respondsToSelector:dw]) {
                id ws = ((id (*)(id, SEL))objc_msgSend)(FBSWS, dw);
                faSet(@"workspace_nil", @(ws == nil));
                SEL ra = NSSelectorFromString(@"runningApplications");
                if (ws && [ws respondsToSelector:ra]) {
                    NSArray *apps = ((id (*)(id, SEL))objc_msgSend)(ws, ra);
                    faSet(@"apps_count", @(apps ? (long)apps.count : -1L));
                    id best = nil;
                    int bestScore = -1;
                    BOOL (*msgB)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
                    for (id a in apps) {
                        int score = 0;
                        if ([a respondsToSelector:NSSelectorFromString(@"visibility")])
                            score = [[a valueForKey:@"visibility"] intValue] * 10;
                        if ([a respondsToSelector:NSSelectorFromString(@"isActive")] &&
                            msgB(a, NSSelectorFromString(@"isActive"))) score += 5;
                        if ([a respondsToSelector:NSSelectorFromString(@"isForeground")] &&
                            msgB(a, NSSelectorFromString(@"isForeground"))) score += 3;
                        if (score > bestScore) { bestScore = score; best = a; }
                    }
                    if (best && bestScore > 0 && [best respondsToSelector:@selector(bundleIdentifier)]) {
                        NSString *bid = ((NSString *(*)(id, SEL))objc_msgSend)(best, @selector(bundleIdentifier));
                        faSet(@"best_score", @(bestScore));
                        if (bid.length) return bid;
                    }
                }
            }
        }
        // 兜底：SBS 符号式
        void *h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
        faSet(@"sbs_dlopen", @(h != NULL));
        if (h) {
            CFStringRef (*copyFn)(void) = (CFStringRef (*)(void))dlsym(h, "SBSCopyFrontmostApplicationDisplayIdentifier");
            faSet(@"sbs_sym_copy", @(copyFn != NULL));
            if (copyFn) {
                CFStringRef r = copyFn();
                faSet(@"sbs_ret_null", @(r == NULL));
                if (r) return (__bridge_transfer NSString *)r;
            }
        }
    } @catch (__unused id e) {}
    return @"";
}
