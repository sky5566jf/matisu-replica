#import "ScreenShot.h"
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>

#if !__has_feature(objc_arc)
#error "ScreenShot.m must be compiled with ARC"
#endif

// 新版 iOS SDK 移除了 IOSurface 的 umbrella header，且 IOSurface 属私有框架；
// 与 AXNodeDump 的 AXRuntime 一致：运行时 dlopen/dlsym，不依赖 SDK 头文件与链接。

typedef struct __IOSurface *IOSurfaceRef;

typedef IOSurfaceRef (*fn_Create)(CFDictionaryRef);
typedef size_t       (*fn_AlignProperty)(CFStringRef, size_t);
typedef size_t       (*fn_GetWidth)(IOSurfaceRef);
typedef size_t       (*fn_GetHeight)(IOSurfaceRef);
typedef size_t       (*fn_GetBytesPerRow)(IOSurfaceRef);
typedef int          (*fn_Lock)(IOSurfaceRef, uint32_t, uint32_t *);
typedef int          (*fn_Unlock)(IOSurfaceRef, uint32_t, uint32_t *);
typedef void *       (*fn_GetBaseAddress)(IOSurfaceRef);
typedef void         (*fn_RenderDisplay)(int, CFStringRef, IOSurfaceRef, int, int);

enum { kMIOSurfaceLockReadOnly = 0x00000001 };

static struct {
    fn_Create          create;
    fn_AlignProperty   alignProperty;
    fn_GetWidth        getWidth;
    fn_GetHeight       getHeight;
    fn_GetBytesPerRow  getBytesPerRow;
    fn_Lock            lock;
    fn_Unlock          unlock;
    fn_GetBaseAddress  getBaseAddress;
    fn_RenderDisplay   renderDisplay;
    CFStringRef       *kBytesPerElement;  // dlsym 出来的是「指向 CFStringRef 常量」的地址
    CFStringRef       *kBytesPerRow;
    CFStringRef       *kWidth;
    CFStringRef       *kHeight;
    CFStringRef       *kPixelFormat;
    CFStringRef       *kAllocSize;
} IO = {0};

// diag：记录加载/捕获内部状态，经 control server 的 diag 指令回传 PC
static NSMutableDictionary *gSDiag = nil;
static void sdiagSet(NSString *k, id v) {
    if (!gSDiag) gSDiag = [NSMutableDictionary dictionary];
    gSDiag[k] = v;
}

static BOOL ioLoad(void) {
    static dispatch_once_t once;
    static BOOL ok = NO;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_LAZY);
        sdiagSet(@"dlopen_IOSurface_fw", @(h != NULL));
        if (!h) h = dlopen("/System/Library/PrivateFrameworks/IOSurface.framework/IOSurface", RTLD_LAZY);
        if (!h) { sdiagSet(@"dlopen_err", @(dlerror() ?: "unknown")); return; }
        IO.create         = (fn_Create)dlsym(h, "IOSurfaceCreate");
        IO.alignProperty  = (fn_AlignProperty)dlsym(h, "IOSurfaceAlignProperty");
        IO.getWidth       = (fn_GetWidth)dlsym(h, "IOSurfaceGetWidth");
        IO.getHeight      = (fn_GetHeight)dlsym(h, "IOSurfaceGetHeight");
        IO.getBytesPerRow = (fn_GetBytesPerRow)dlsym(h, "IOSurfaceGetBytesPerRow");
        IO.lock           = (fn_Lock)dlsym(h, "IOSurfaceLock");
        IO.unlock         = (fn_Unlock)dlsym(h, "IOSurfaceUnlock");
        IO.getBaseAddress = (fn_GetBaseAddress)dlsym(h, "IOSurfaceGetBaseAddress");
        IO.kBytesPerElement = (CFStringRef *)dlsym(h, "kIOSurfaceBytesPerElement");
        IO.kBytesPerRow     = (CFStringRef *)dlsym(h, "kIOSurfaceBytesPerRow");
        IO.kWidth           = (CFStringRef *)dlsym(h, "kIOSurfaceWidth");
        IO.kHeight          = (CFStringRef *)dlsym(h, "kIOSurfaceHeight");
        IO.kPixelFormat     = (CFStringRef *)dlsym(h, "kIOSurfacePixelFormat");
        IO.kAllocSize       = (CFStringRef *)dlsym(h, "kIOSurfaceAllocSize");
        sdiagSet(@"sym_create", @(IO.create != NULL));
        sdiagSet(@"sym_getWidth", @(IO.getWidth != NULL));
        sdiagSet(@"sym_lock", @(IO.lock != NULL));
        sdiagSet(@"sym_getBaseAddress", @(IO.getBaseAddress != NULL));
        sdiagSet(@"key_kWidth", @(IO.kWidth != NULL));
        sdiagSet(@"key_kBytesPerRow", @(IO.kBytesPerRow != NULL));
        if (!IO.create || !IO.getWidth || !IO.getHeight || !IO.getBytesPerRow ||
            !IO.lock || !IO.unlock || !IO.getBaseAddress ||
            !IO.kBytesPerElement || !IO.kBytesPerRow || !IO.kWidth ||
            !IO.kHeight || !IO.kPixelFormat || !IO.kAllocSize) return;
        // CARenderServerRenderDisplay 在 QuartzCore（UIKit 已加载，先试全局符号表）
        IO.renderDisplay = (fn_RenderDisplay)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
        sdiagSet(@"sym_renderDisplay_global", @(IO.renderDisplay != NULL));
        if (!IO.renderDisplay) {
            void *qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY | RTLD_GLOBAL);
            sdiagSet(@"dlopen_QuartzCore", @(qc != NULL));
            if (qc) IO.renderDisplay = (fn_RenderDisplay)dlsym(qc, "CARenderServerRenderDisplay");
        }
        sdiagSet(@"sym_renderDisplay", @(IO.renderDisplay != NULL));
        if (!IO.renderDisplay) return;
        ok = YES;
    });
    sdiagSet(@"io_ok", @(ok));
    return ok;
}

NSDictionary* MatisuScreenDiag(void) {
    BOOL ok = ioLoad();
    sdiagSet(@"io_ok", @(ok));
    return gSDiag ?: @{};
}

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
    sdiagSet(@"surf_scale", @(scale));
    sdiagSet(@"surf_pts", [NSString stringWithFormat:@"%.0fx%.0f", pts.width, pts.height]);
    sdiagSet(@"surf_wh", [NSString stringWithFormat:@"%dx%d", w, h]);
    if (w <= 0 || h <= 0) { sdiagSet(@"fail_step", @"surf_size_zero"); return NULL; }

    unsigned pixelFormat = 0x42475241; // 'ARGB'
    int bpp = 4;                       // 每像素 4 字节
    int bpr = (int)(IO.alignProperty ? IO.alignProperty(*IO.kBytesPerRow, bpp * w) : (size_t)(bpp * w));
    sdiagSet(@"surf_bpr", @(bpr));

    NSDictionary *props = @{
        (__bridge NSString *)*IO.kBytesPerElement : @(bpp),
        (__bridge NSString *)*IO.kBytesPerRow     : @(bpr),
        (__bridge NSString *)*IO.kWidth           : @(w),
        (__bridge NSString *)*IO.kHeight          : @(h),
        (__bridge NSString *)*IO.kPixelFormat     : @(pixelFormat),
        (__bridge NSString *)*IO.kAllocSize       : @(bpr * h),
    };
    gSurface = IO.create((__bridge CFDictionaryRef)props);
    sdiagSet(@"surf_create_null", @(gSurface == NULL));
    return gSurface;
}

NSData *_Nullable MatisuCapturePNG(void) {
    if (!ioLoad()) { sdiagSet(@"fail_step", @"ioLoad"); return nil; }
    IOSurfaceRef s = ensureSurface();
    if (!s) { sdiagSet(@"fail_step", @"ensureSurface"); return nil; }

    // 整屏 -> IOSurface（"LCD" 为主显示）
    IO.renderDisplay(0, CFSTR("LCD"), s, 0, 0);

    int w = (int)IO.getWidth(s);
    int h = (int)IO.getHeight(s);
    int bpr = (int)IO.getBytesPerRow(s);
    if (w <= 0 || h <= 0) { sdiagSet(@"fail_step", @"zero_size"); return nil; }

    IO.lock(s, kMIOSurfaceLockReadOnly, NULL);
    void *base = IO.getBaseAddress(s);
    sdiagSet(@"base_null", @(base == NULL));

    // IOSurface 为 ARGB（字节序 A,R,G,B），用 kCGImageAlphaFirst | ByteOrder32Big 解释
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs,
                                             kCGImageAlphaFirst | kCGBitmapByteOrder32Big);
    CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    IO.unlock(s, kMIOSurfaceLockReadOnly, NULL);
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
