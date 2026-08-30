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

        info = [NSMutableDictionary dictionary];
        info[@"name"]          = dev.name ?: @"";
        info[@"model"]         = machineId();
        info[@"modelName"]     = dev.model ?: @"";
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
