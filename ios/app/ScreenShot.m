#import "ScreenShot.h"
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

#if !__has_feature(objc_arc)
#error "ScreenShot.m must be compiled with ARC"
#endif

// IOSurface 符号自声明并直接链接（与 TrollVNC 同一做法）：
// 新版 iOS SDK 删了 IOSurface umbrella header，但框架 tbd 仍可链接、符号均在；
// 曾用 dlopen/dlsym 方式，实测 iOS 16 真机上 IOSurfaceCreate 稳定返回 NULL，故改为直链。

typedef struct __IOSurface *IOSurfaceRef;

#ifdef __cplusplus
extern "C" {
#endif

extern const CFStringRef kIOSurfaceAllocSize;
extern const CFStringRef kIOSurfaceBytesPerElement;
extern const CFStringRef kIOSurfaceBytesPerRow;
extern const CFStringRef kIOSurfaceColorSpace;
extern const CFStringRef kIOSurfaceHeight;
extern const CFStringRef kIOSurfacePixelFormat;
extern const CFStringRef kIOSurfaceWidth;

size_t       IOSurfaceAlignProperty(CFStringRef property, size_t value);
IOSurfaceRef IOSurfaceCreate(CFDictionaryRef properties);
size_t       IOSurfaceGetWidth(IOSurfaceRef buffer);
size_t       IOSurfaceGetHeight(IOSurfaceRef buffer);
size_t       IOSurfaceGetBytesPerRow(IOSurfaceRef buffer);
int          IOSurfaceLock(IOSurfaceRef buffer, uint32_t options, uint32_t *seed);
int          IOSurfaceUnlock(IOSurfaceRef buffer, uint32_t options, uint32_t *seed);
void *       IOSurfaceGetBaseAddress(IOSurfaceRef buffer);

// 私有 SPI：把指定 IOSurface 渲染为整屏内容（iOS 13+）。weak_import 以便旧系统也能链接。
void CARenderServerRenderDisplay(int a, CFStringRef b, IOSurfaceRef surface, int x, int y)
    __attribute__((weak_import));

#ifdef __cplusplus
}
#endif

// UIScreen 私有 API（iOS 13+）：不受 App 兼容模式影响的物理像素尺寸
@interface UIScreen (MatisuPrivate)
- (CGRect)_unjailedReferenceBoundsInPixels;
@end

enum { kMIOSurfaceLockReadOnly = 0x00000001 };

// diag：记录捕获内部状态，经 control server 的 diag 指令回传 PC
static NSMutableDictionary *gSDiag = nil;
static void sdiagSet(NSString *k, id v) {
    if (!gSDiag) gSDiag = [NSMutableDictionary dictionary];
    gSDiag[k] = v;
}

// 截屏目标 IOSurface（创建一次后复用）
static IOSurfaceRef gSurface = NULL;

static IOSurfaceRef ensureSurface(void) {
    if (gSurface) return gSurface;

    // 优先私有 API 拿真实物理分辨率；失败退回 nativeBounds
    int w = 0, h = 0;
    if ([UIScreen instancesRespondToSelector:@selector(_unjailedReferenceBoundsInPixels)]) {
        CGSize px = [UIScreen mainScreen]._unjailedReferenceBoundsInPixels.size;
        w = (int)round(px.width);
        h = (int)round(px.height);
        sdiagSet(@"size_src", @"unjailed");
    }
    if (w <= 0 || h <= 0) {
        CGRect nb = [UIScreen mainScreen].nativeBounds;
        w = (int)round(nb.size.width);
        h = (int)round(nb.size.height);
        sdiagSet(@"size_src", @"nativeBounds");
    }
    sdiagSet(@"surf_wh", [NSString stringWithFormat:@"%dx%d", w, h]);
    if (w <= 0 || h <= 0) { sdiagSet(@"fail_step", @"surf_size_zero"); return NULL; }

    unsigned pixelFormat = 0x42475241;   // 'BGRA'（TrollVNC 同款值）
    int bpp = 4;                          // 每像素 4 字节
    int bpr = (int)IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, bpp * w);
    sdiagSet(@"surf_bpr", @(bpr));

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CFPropertyListRef cspl = cs ? CGColorSpaceCopyPropertyList(cs) : NULL;
    if (cs) CGColorSpaceRelease(cs);

    NSMutableDictionary *props = [@{
        (__bridge NSString *)kIOSurfaceBytesPerElement : @(bpp),
        (__bridge NSString *)kIOSurfaceBytesPerRow     : @(bpr),
        (__bridge NSString *)kIOSurfaceWidth           : @(w),
        (__bridge NSString *)kIOSurfaceHeight          : @(h),
        (__bridge NSString *)kIOSurfacePixelFormat     : @(pixelFormat),
        (__bridge NSString *)kIOSurfaceAllocSize       : @(bpr * h),
    } mutableCopy];
    if (cspl) props[(__bridge NSString *)kIOSurfaceColorSpace] = CFBridgingRelease(cspl);

    gSurface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    sdiagSet(@"surf_create_null", @(gSurface == NULL));
    return gSurface;
}

NSData *_Nullable MatisuCapturePNG(void) {
    if (CARenderServerRenderDisplay == NULL) { sdiagSet(@"fail_step", @"no_render_spi"); return nil; }
    IOSurfaceRef s = ensureSurface();
    if (!s) { sdiagSet(@"fail_step", @"ensureSurface"); return nil; }

    // 整屏 -> IOSurface（"LCD" 为主显示）
    CARenderServerRenderDisplay(0, CFSTR("LCD"), s, 0, 0);

    int w = (int)IOSurfaceGetWidth(s);
    int h = (int)IOSurfaceGetHeight(s);
    int bpr = (int)IOSurfaceGetBytesPerRow(s);
    if (w <= 0 || h <= 0) { sdiagSet(@"fail_step", @"zero_size"); return nil; }

    IOSurfaceLock(s, kMIOSurfaceLockReadOnly, NULL);
    void *base = IOSurfaceGetBaseAddress(s);
    sdiagSet(@"base_null", @(base == NULL));

    // 像素格式 BGRA 小端：用 kCGImageAlphaNoneSkipFirst | ByteOrder32Little 解释
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs,
                                             kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    IOSurfaceUnlock(s, kMIOSurfaceLockReadOnly, NULL);
    CGColorSpaceRelease(cs);
    if (ctx) CGContextRelease(ctx);
    if (!img) { sdiagSet(@"fail_step", @"make_image"); return nil; }
    sdiagSet(@"fail_step", @"none");
    sdiagSet(@"cap_size", [NSString stringWithFormat:@"%dx%d bpr=%d", w, h, bpr]);

    UIImage *u = [UIImage imageWithCGImage:img];
    NSData *png = UIImagePNGRepresentation(u);
    CGImageRelease(img);
    return png;
}

NSDictionary* _Nullable MatisuScreenDiag(void) {
    return gSDiag ?: @{};
}

// 设备端 Lua 引擎用：截屏到共享 surface 并直读单像素（0xBBGGRR 原版契约），不做 PNG 编码。
// 入参为逻辑点坐标（与触控同空间），内部按 surface 物理尺寸等比换算。
int MatisuCapturePixel(int x, int y) {
    if (CARenderServerRenderDisplay == NULL) return -1;
    IOSurfaceRef s = ensureSurface();
    if (!s) return -1;
    CARenderServerRenderDisplay(0, CFSTR("LCD"), s, 0, 0);

    int sw = (int)IOSurfaceGetWidth(s);
    int sh = (int)IOSurfaceGetHeight(s);
    int bpr = (int)IOSurfaceGetBytesPerRow(s);
    if (sw <= 0 || sh <= 0) return -1;

    // 逻辑点 -> 物理像素（逻辑宽取 UIScreen.bounds，daemon 下为显示缩放真实值）
    __block CGSize lb = CGSizeZero;
    void (^rd)(void) = ^{ lb = [UIScreen mainScreen].bounds.size; };
    if ([NSThread isMainThread]) rd();
    else dispatch_sync(dispatch_get_main_queue(), rd);
    if (lb.width <= 0 || lb.height <= 0) return -1;
    int px = (int)lroundf((float)x / (float)lb.width * sw);
    int py = (int)lroundf((float)y / (float)lb.height * sh);
    if (px < 0 || py < 0 || px >= sw || py >= sh) return -1;

    IOSurfaceLock(s, kMIOSurfaceLockReadOnly, NULL);
    const uint8_t *base = (const uint8_t *)IOSurfaceGetBaseAddress(s);
    int ret = -1;
    if (base) {
        const uint8_t *p = base + (size_t)py * (size_t)bpr + (size_t)px * 4;
        ret = (p[0] << 16) | (p[1] << 8) | p[2];   // BGRA -> 0xBBGGRR（原版契约格式）
    }
    IOSurfaceUnlock(s, kMIOSurfaceLockReadOnly, NULL);
    return ret;
}

// 批量读取锁：render + lock 一次，供 ColorFind 全屏扫描
const uint8_t* _Nullable MatisuSurfaceLockRead(int *outW, int *outH, int *outBpr) {
    if (CARenderServerRenderDisplay == NULL) return NULL;
    IOSurfaceRef s = ensureSurface();
    if (!s) return NULL;
    CARenderServerRenderDisplay(0, CFSTR("LCD"), s, 0, 0);
    int w = (int)IOSurfaceGetWidth(s), h = (int)IOSurfaceGetHeight(s), bpr = (int)IOSurfaceGetBytesPerRow(s);
    if (w <= 0 || h <= 0) return NULL;
    if (IOSurfaceLock(s, kMIOSurfaceLockReadOnly, NULL) != 0) return NULL;
    const uint8_t *base = (const uint8_t *)IOSurfaceGetBaseAddress(s);
    if (!base) { IOSurfaceUnlock(s, kMIOSurfaceLockReadOnly, NULL); return NULL; }
    if (outW) *outW = w;
    if (outH) *outH = h;
    if (outBpr) *outBpr = bpr;
    return base;
}

void MatisuSurfaceUnlockRead(void) {
    if (gSurface) IOSurfaceUnlock(gSurface, kMIOSurfaceLockReadOnly, NULL);
}
