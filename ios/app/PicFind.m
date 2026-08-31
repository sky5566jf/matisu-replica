// MatisuAuto — 设备端找图实现
#import "PicFind.h"
#import "ScreenShot.h"
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

// ---------------- 模板 PNG 解码（CG -> RGBA 缓冲） ----------------
typedef struct {
    int w, h;
    uint8_t *rgba;   // w*h*4
} MATemplate;

static BOOL loadTemplate(NSString *path, MATemplate *out) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d.length) return NO;
    CGDataProviderRef prov = CGDataProviderCreateWithCFData((__bridge CFDataRef)d);
    CGImageRef img = prov ? CGImageCreateWithPNGDataProvider(prov, NULL, false, kCGRenderingIntentDefault) : NULL;
    if (prov) CGDataProviderRelease(prov);
    if (!img) return NO;

    int w = (int)CGImageGetWidth(img), h = (int)CGImageGetHeight(img);
    if (w <= 0 || h <= 0 || w > 1024 || h > 1024) { CGImageRelease(img); return NO; }
    uint8_t *buf = (uint8_t *)calloc((size_t)w * h * 4, 1);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, (size_t)w * 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); CGImageRelease(img); return NO; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
    CGContextRelease(ctx);
    CGImageRelease(img);
    out->w = w; out->h = h; out->rgba = buf;
    return YES;
}

// ---------------- 逻辑点 <-> 物理像素 ----------------
static void maLogicalSize(float *lw, float *lh) {
    __block CGSize lb = CGSizeZero;
    void (^rd)(void) = ^{ lb = [UIScreen mainScreen].bounds.size; };
    if ([NSThread isMainThread]) rd();
    else dispatch_sync(dispatch_get_main_queue(), rd);
    *lw = lb.width > 0 ? (float)lb.width : 320.0f;
    *lh = lb.height > 0 ? (float)lb.height : 568.0f;
}

// ---------------- NCC-lite 匹配（PC matchTemplate 同源） ----------------
typedef struct {
    const uint8_t *scr;  // BGRA
    int sw, sh, bpr;
} MAFrame;

static inline double tplScoreAt(MAFrame *f, const MATemplate *t, const uint8_t *mask,
                                int px, int py, int useMask) {
    long diff = 0, cnt = 0;
    for (int ty = 0; ty < t->h; ty++) {
        const uint8_t *srow = f->scr + (size_t)(py + ty) * f->bpr + (size_t)px * 4;
        const uint8_t *trow = t->rgba + (size_t)ty * t->w * 4;
        for (int tx = 0; tx < t->w; tx++) {
            if (useMask && mask[ty * t->w + tx] < 128) continue;
            const uint8_t *sp = srow + (size_t)tx * 4;
            const uint8_t *tp = trow + (size_t)tx * 4;
            diff += labs(sp[0] - tp[0]) + labs(sp[1] - tp[1]) + labs(sp[2] - tp[2]);
            cnt += 3;
        }
    }
    if (!cnt) return 0;
    return 1.0 - ((double)diff / (double)cnt) / 255.0;
}

static BOOL matchTemplate(MAFrame *f, const MATemplate *t, int X1, int Y1, int X2, int Y2,
                          double sim, int useMask, int *outX, int *outY, double *outS) {
    int x2 = MIN(X2 - t->w, f->sw - t->w), y2 = MIN(Y2 - t->h, f->sh - t->h);
    if (x2 < X1 || y2 < Y1) return NO;

    // alpha mask（findPicEx 用）
    uint8_t *mask = NULL;
    if (useMask) {
        mask = (uint8_t *)malloc((size_t)t->w * t->h);
        for (int i = 0; i < t->w * t->h; i++) mask[i] = t->rgba[i * 4 + 3];
    }

    int step = MAX(2, MIN(t->w, t->h) >> 3);
    // 粗扫 + 9 点预筛
    int cap = 4096, nCand = 0;
    int *cands = (int *)malloc(sizeof(int) * 2 * cap);
    for (int y = Y1; y <= y2; y += step) {
        for (int x = X1; x <= x2; x += step) {
            long pre = 0; int pc = 0;
            for (int k = 0; k < 9; k++) {
                int tx = (k % 3) * (t->w >> 2) + (t->w >> 3);
                int ty = (k / 3) * (t->h >> 2) + (t->h >> 3);
                if (useMask && mask[ty * t->w + tx] < 128) continue;
                const uint8_t *sp = f->scr + (size_t)(y + ty) * f->bpr + (size_t)(x + tx) * 4;
                const uint8_t *tp = t->rgba + (size_t)(ty * t->w + tx) * 4;
                pre += labs(sp[0] - tp[0]) + labs(sp[1] - tp[1]) + labs(sp[2] - tp[2]);
                pc += 3;
            }
            if (pc && 1.0 - ((double)pre / pc) / 255.0 >= sim - 0.15) {
                if (nCand < cap) { cands[nCand * 2] = x; cands[nCand * 2 + 1] = y; nCand++; }
            }
        }
    }

    BOOL found = NO;
    double bestS = 0; int bestX = 0, bestY = 0;
    for (int i = 0; i < nCand; i++) {
        int cx = cands[i * 2], cy = cands[i * 2 + 1];
        int x1r = MAX(X1, cx - step), y1r = MAX(Y1, cy - step);
        int x2r = MIN(x2, cx + step), y2r = MIN(y2, cy + step);
        for (int y = y1r; y <= y2r; y++) for (int x = x1r; x <= x2r; x++) {
            double s = tplScoreAt(f, t, mask, x, y, useMask);
            if (s >= sim && (!found || s > bestS)) { found = YES; bestS = s; bestX = x; bestY = y; }
        }
    }
    free(cands);
    if (mask) free(mask);
    if (!found) return NO;
    *outX = bestX; *outY = bestY;
    if (outS) *outS = bestS;
    return YES;
}

// ---------------- 对外实现 ----------------
static int findPicImpl(int x1, int y1, int x2, int y2, NSString *picPath, double sim,
                       int useMask, int *outX, int *outY) {
    MATemplate t = {0};
    if (!loadTemplate(picPath, &t)) return 0;
    int sw = 0, sh = 0, bpr = 0;
    const uint8_t *base = MatisuSurfaceLockRead(&sw, &sh, &bpr);
    if (!base) { free(t.rgba); return 0; }

    float lw, lh;
    maLogicalSize(&lw, &lh);
    float kx = (float)sw / lw, ky = (float)sh / lh;
    int X1 = 0, Y1 = 0, X2 = sw, Y2 = sh;
    if (!(x1 == 0 && y1 == 0 && x2 == 0 && y2 == 0)) {
        X1 = MAX(0, (int)lroundf(x1 * kx)); Y1 = MAX(0, (int)lroundf(y1 * ky));
        X2 = MIN(sw, (int)lroundf(x2 * kx)); Y2 = MIN(sh, (int)lroundf(y2 * ky));
    }
    MAFrame f = { base, sw, sh, bpr };
    int hx = -1, hy = -1;
    double s = 0;
    BOOL ok = matchTemplate(&f, &t, X1, Y1, X2, Y2, sim <= 0 ? 0.9 : sim, useMask, &hx, &hy, &s);
    MatisuSurfaceUnlockRead();
    free(t.rgba);
    if (!ok) return 0;
    if (outX) *outX = (int)lroundf(hx / kx);
    if (outY) *outY = (int)lroundf(hy / ky);
    return 1;
}

int MatisuFindPic(int x1, int y1, int x2, int y2, NSString *picPath, double sim, int *outX, int *outY) {
    return findPicImpl(x1, y1, x2, y2, picPath, sim, 0, outX, outY);
}

int MatisuFindPicEx(int x1, int y1, int x2, int y2, NSString *picPath, double sim, int *outX, int *outY) {
    return findPicImpl(x1, y1, x2, y2, picPath, sim, 1, outX, outY);
}

NSData* _Nullable MatisuCapturePNGRegion(int x1, int y1, int x2, int y2) {
    int sw = 0, sh = 0, bpr = 0;
    const uint8_t *base = MatisuSurfaceLockRead(&sw, &sh, &bpr);
    if (!base) return nil;

    float lw, lh;
    maLogicalSize(&lw, &lh);
    float kx = (float)sw / lw, ky = (float)sh / lh;
    int X1 = 0, Y1 = 0, X2 = sw, Y2 = sh;
    if (!(x1 == 0 && y1 == 0 && x2 == 0 && y2 == 0)) {
        X1 = MAX(0, (int)lroundf(x1 * kx)); Y1 = MAX(0, (int)lroundf(y1 * ky));
        X2 = MIN(sw, (int)lroundf(x2 * kx)); Y2 = MIN(sh, (int)lroundf(y2 * ky));
    }
    int cw = X2 - X1, ch = Y2 - Y1;
    if (cw <= 0 || ch <= 0) { MatisuSurfaceUnlockRead(); return nil; }

    // 裁剪到连续 RGBA 缓冲（BGRA 直通，PNG 编码器按 RGBA 写出由 CG 处理）
    uint8_t *crop = (uint8_t *)malloc((size_t)cw * ch * 4);
    for (int y = 0; y < ch; y++)
        memcpy(crop + (size_t)y * cw * 4, base + (size_t)(Y1 + y) * bpr + (size_t)X1 * 4, (size_t)cw * 4);
    MatisuSurfaceUnlockRead();

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(crop, cw, ch, 8, (size_t)cw * 4, cs,
                                             kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    if (ctx) CGContextRelease(ctx);
    free(crop);
    if (!img) return nil;
    UIImage *u = [UIImage imageWithCGImage:img];
    NSData *png = UIImagePNGRepresentation(u);
    CGImageRelease(img);
    return png;
}
