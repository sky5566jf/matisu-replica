#import "ScreenShot.h"
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurface.h>

#if !__has_feature(objc_arc)
#error "ScreenShot.m must be compiled with ARC"
#endif

// 私有 SPI：把指定 IOSurface 渲染为整屏内容（iOS 13+）。weak_import 以便旧系统也能链接。
extern void CARenderServerRenderDisplay(kern_return_t a, CFStringRef b, IOSurfaceRef surface, int x, int y)
    __attribute__((weak_import));

// 截屏目标 IOSurface（创建一次后复用）
static IOSurfaceRef gSurface = NULL;

static IOSurfaceRef ensureSurface(void) {
    if (gSurface) return gSurface;
    CGFloat scale = [UIScreen mainScreen].scale;
    CGSize pts = [UIScreen mainScreen].bounds.size;
    int w = (int)round(pts.width * scale);
    int h = (int)round(pts.height * scale);
    // scale 不可靠时退回 nativeBounds（物理像素）
    if (w <= 0 || h <= 0) {
        CGRect nb = [UIScreen mainScreen].nativeBounds;
        w = (int)round(nb.size.width);
        h = (int)round(nb.size.height);
    }
    if (w <= 0 || h <= 0) return NULL;

    unsigned pixelFormat = 0x42475241; // 'ARGB'
    int bpp = 4;                       // 每像素 4 字节
    int bpr = (int)IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, bpp * w);

    NSDictionary *props = @{
        (__bridge NSString *)kIOSurfaceBytesPerElement : @(bpp),
        (__bridge NSString *)kIOSurfaceBytesPerRow     : @(bpr),
        (__bridge NSString *)kIOSurfaceWidth           : @(w),
        (__bridge NSString *)kIOSurfaceHeight          : @(h),
        (__bridge NSString *)kIOSurfacePixelFormat     : @(pixelFormat),
        (__bridge NSString *)kIOSurfaceAllocSize       : @(bpr * h),
    };
    gSurface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    return gSurface;
}

NSData *_Nullable MatisuCapturePNG(void) {
    IOSurfaceRef s = ensureSurface();
    if (!s || CARenderServerRenderDisplay == NULL) return nil;

    // 整屏 -> IOSurface（"LCD" 为主显示）
    CARenderServerRenderDisplay(0, CFSTR("LCD"), s, 0, 0);

    int w = (int)IOSurfaceGetWidth(s);
    int h = (int)IOSurfaceGetHeight(s);
    int bpr = (int)IOSurfaceGetBytesPerRow(s);
    if (w <= 0 || h <= 0) return nil;

    IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
    void *base = IOSurfaceGetBaseAddress(s);

    // IOSurface 为 ARGB（字节序 A,R,G,B），用 kCGImageAlphaFirst | ByteOrder32Big 解释
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs,
                                             kCGImageAlphaFirst | kCGBitmapByteOrder32Big);
    CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
    CGColorSpaceRelease(cs);
    if (ctx) CGContextRelease(ctx);
    if (!img) return nil;

    UIImage *u = [UIImage imageWithCGImage:img];
    NSData *png = UIImagePNGRepresentation(u);
    CGImageRelease(img);
    return png;
}
