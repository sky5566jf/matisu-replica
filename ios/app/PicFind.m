// MatisuAuto — 设备端找图实现
#import "PicFind.h"
#import "ScreenShot.h"
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>

// ---------------- 模板 PNG 解码（CG -> RGBA 缓冲） ----------------
typedef struct {
    int w, h;
    uint8_t *rgba;   // w*h*4
} MATemplate;

// 找图多命中点（NMS 用）；文件级类型便于 qsort 比较器引用
typedef struct {
    int x, y;
    double s;
} MAHit;

// qsort 比较器（C 函数指针，不能用 block——qsort 要的是函数指针）
static int maHitScoreCmp(const void *a, const void *b) {
    double sa = ((const MAHit *)a)->s, sb = ((const MAHit *)b)->s;
    return sa < sb ? 1 : (sa > sb ? -1 : 0);
}

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
// 缩帧（最近邻），factor=2 表示 1/2 尺寸；BGRA 直通
static void shrinkFrame(const uint8_t *src, int sw, int sh, int bpr, int factor,
                        uint8_t *dst, int *dw, int *dh) {
    int w = sw / factor, h = sh / factor;
    for (int y = 0; y < h; y++) {
        const uint8_t *srow = src + (size_t)(y * factor) * bpr;
        uint8_t *drow = dst + (size_t)y * w * 4;
        for (int x = 0; x < w; x++)
            memcpy(drow + (size_t)x * 4, srow + (size_t)(x * factor) * 4, 4);
    }
    *dw = w; *dh = h;
}
static void shrinkTemplate(const MATemplate *t, int factor, MATemplate *out) {
    int w = t->w / factor, h = t->h / factor;
    uint8_t *buf = (uint8_t *)malloc((size_t)w * h * 4);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++)
        memcpy(buf + (size_t)(y * w + x) * 4, t->rgba + (size_t)((y * factor) * t->w + x * factor) * 4, 4);
    out->w = w; out->h = h; out->rgba = buf;
}

static int findPicImpl(int x1, int y1, int x2, int y2, NSString *picPath, double sim,
                       int useMask, int *outX, int *outY) {
    MATemplate t0 = {0};
    if (!loadTemplate(picPath, &t0)) return 0;
    int sw = 0, sh = 0, bpr = 0;
    const uint8_t *base = MatisuSurfaceLockRead(&sw, &sh, &bpr);
    if (!base) { free(t0.rgba); return 0; }

    // 模板/帧同步缩到 ~逻辑分辨率再匹配（物理帧全量匹配代价超 60 倍，实测卡死 18182）
    float lw, lh;
    maLogicalSize(&lw, &lh);
    float kx = (float)sw / lw, ky = (float)sh / lh;
    int factor = MAX(1, (int)lroundf(kx));   // 显示缩放机 kx=2 → 1/2 缩帧

    int dw = 0, dh = 0;
    uint8_t *small = (uint8_t *)malloc((size_t)(sw / factor) * (sh / factor) * 4);
    shrinkFrame(base, sw, sh, bpr, factor, small, &dw, &dh);
    MatisuSurfaceUnlockRead();   // 帧数据已拷出，尽早放锁

    MATemplate t = {0};
    shrinkTemplate(&t0, factor, &t);
    free(t0.rgba);
    if (t.w < 4 || t.h < 4) { free(small); free(t.rgba); return 0; }

    int X1 = 0, Y1 = 0, X2 = dw, Y2 = dh;
    if (!(x1 == 0 && y1 == 0 && x2 == 0 && y2 == 0)) {
        // 逻辑点区域 -> 缩帧坐标（逻辑点 ≈ 缩帧像素，factor≈kx）
        X1 = MAX(0, (int)lroundf(x1 * kx / factor)); Y1 = MAX(0, (int)lroundf(y1 * ky / factor));
        X2 = MIN(dw, (int)lroundf(x2 * kx / factor)); Y2 = MIN(dh, (int)lroundf(y2 * ky / factor));
    }
    MAFrame f = { small, dw, dh, dw * 4 };
    int hx = -1, hy = -1;
    double s = 0;
    BOOL ok = matchTemplate(&f, &t, X1, Y1, X2, Y2, sim <= 0 ? 0.9 : sim, useMask, &hx, &hy, &s);
    free(small);
    free(t.rgba);
    if (!ok) return 0;
    // 缩帧命中点 -> 逻辑点（factor 与 kx/ky 抵消回逻辑空间）
    if (outX) *outX = (int)lroundf(hx * (double)factor / kx);
    if (outY) *outY = (int)lroundf(hy * (double)factor / ky);
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

// ---------------- 全部命中点（NMS） ----------------
int MatisuFindPicAllPoint(int x1, int y1, int x2, int y2, NSString *picPath, double sim,
                          int maxRet, int * _Nonnull * _Nonnull outXY, int * _Nonnull outN) {
    *outXY = NULL; *outN = 0;
    MATemplate t0 = {0};
    if (!loadTemplate(picPath, &t0)) return 0;
    int sw = 0, sh = 0, bpr = 0;
    const uint8_t *base = MatisuSurfaceLockRead(&sw, &sh, &bpr);
    if (!base) { free(t0.rgba); return 0; }

    float lw, lh; maLogicalSize(&lw, &lh);
    float kx = (float)sw / lw, ky = (float)sh / lh;
    int factor = MAX(1, (int)lroundf(kx));

    int dw = 0, dh = 0;
    uint8_t *small = (uint8_t *)malloc((size_t)(sw / factor) * (sh / factor) * 4);
    shrinkFrame(base, sw, sh, bpr, factor, small, &dw, &dh);
    MatisuSurfaceUnlockRead();

    MATemplate t = {0};
    shrinkTemplate(&t0, factor, &t);
    free(t0.rgba);
    if (t.w < 4 || t.h < 4) { free(small); free(t.rgba); return 0; }

    int X1 = 0, Y1 = 0, X2 = dw, Y2 = dh;
    if (!(x1 == 0 && y1 == 0 && x2 == 0 && y2 == 0)) {
        X1 = MAX(0, (int)lroundf(x1 * kx / factor)); Y1 = MAX(0, (int)lroundf(y1 * ky / factor));
        X2 = MIN(dw, (int)lroundf(x2 * kx / factor)); Y2 = MIN(dh, (int)lroundf(y2 * ky / factor));
    }
    MAFrame f = { small, dw, dh, dw * 4 };

    int x2b = MIN(X2 - t.w, f.sw - t.w), y2b = MIN(Y2 - t.h, f.sh - t.h);
    if (x2b < X1 || y2b < Y1) { free(small); free(t.rgba); return 0; }

    int step = MAX(2, MIN(t.w, t.h) >> 3);
    int cap = 8192, nCand = 0;
    int *cands = (int *)malloc(sizeof(int) * 2 * cap);
    for (int y = Y1; y <= y2b; y += step) {
        for (int x = X1; x <= x2b; x += step) {
            // 9 点预筛
            long pre = 0; int pc = 0;
            for (int k = 0; k < 9; k++) {
                int tx = (k % 3) * (t.w >> 2) + (t.w >> 3);
                int ty = (k / 3) * (t.h >> 2) + (t.h >> 3);
                const uint8_t *sp = f.scr + (size_t)(y + ty) * f.bpr + (size_t)(x + tx) * 4;
                const uint8_t *tp = t.rgba + (size_t)(ty * t.w + tx) * 4;
                pre += labs(sp[0] - tp[0]) + labs(sp[1] - tp[1]) + labs(sp[2] - tp[2]);
                pc += 3;
            }
            if (pc && 1.0 - ((double)pre / pc) / 255.0 >= sim - 0.15) {
                if (nCand < cap) { cands[nCand * 2] = x; cands[nCand * 2 + 1] = y; nCand++; }
            }
        }
    }

    // 精修收集
    MAHit *hits = (MAHit *)malloc(sizeof(MAHit) * (nCand + 1));
    int nHits = 0;
    for (int i = 0; i < nCand; i++) {
        int cx = cands[i * 2], cy = cands[i * 2 + 1];
        int x1r = MAX(X1, cx - step), y1r = MAX(Y1, cy - step);
        int x2r = MIN(x2b, cx + step), y2r = MIN(y2b, cy + step);
        for (int y = y1r; y <= y2r; y++) for (int x = x1r; x <= x2r; x++) {
            double s = tplScoreAt(&f, &t, NULL, x, y, 0);
            if (s >= sim) { hits[nHits].x = x; hits[nHits].y = y; hits[nHits].s = s; nHits++; break; }
        }
    }
    free(cands); free(small); free(t.rgba);

    if (nHits == 0) { free(hits); return 0; }

    // NMS：按分数降序，minDist=模板较大边一半（缩帧坐标）
    int minDist = MAX(t.w, t.h) / 2 + 1;
    qsort(hits, nHits, sizeof(MAHit), maHitScoreCmp);
    int *keep = (int *)malloc(sizeof(int) * nHits);
    int nKeep = 0;
    for (int i = 0; i < nHits; i++) {
        int ok = 1;
        for (int j = 0; j < nKeep; j++) {
            int dx = hits[i].x - hits[keep[j]].x, dy = hits[i].y - hits[keep[j]].y;
            if (dx * dx + dy * dy < minDist * minDist) { ok = 0; break; }
        }
        if (ok) keep[nKeep++] = i;
        if (maxRet > 0 && nKeep >= maxRet) break;
    }

    int *xy = (int *)malloc(sizeof(int) * 2 * nKeep);
    for (int i = 0; i < nKeep; i++) {
        int h = keep[i];
        xy[i * 2]     = (int)lroundf(hits[h].x * (double)factor / kx);
        xy[i * 2 + 1] = (int)lroundf(hits[h].y * (double)factor / ky);
    }
    free(hits); free(keep);
    *outXY = xy; *outN = nKeep;
    return nKeep > 0 ? 1 : 0;
}

// ---------------- 霍夫圆检测 ----------------
int MatisuFindCircle(int x1, int y1, int x2, int y2,
                     int dp, int minDist, int p1, int p2, int minR, int maxR,
                     int *outCx, int *outCy, int *outR) {
    if (dp < 1) dp = 1;
    if (minR < 1) minR = 1;
    if (maxR < minR) maxR = minR;

    int sw = 0, sh = 0, bpr = 0;
    const uint8_t *base = MatisuSurfaceLockRead(&sw, &sh, &bpr);
    if (!base) return 0;

    float lw, lh; maLogicalSize(&lw, &lh);
    float kx = (float)sw / lw, ky = (float)sh / lh;
    int factor = MAX(1, (int)lroundf(kx));

    int dw = 0, dh = 0;
    uint8_t *small = (uint8_t *)malloc((size_t)(sw / factor) * (sh / factor) * 4);
    shrinkFrame(base, sw, sh, bpr, factor, small, &dw, &dh);
    MatisuSurfaceUnlockRead();

    int X1 = 0, Y1 = 0, X2 = dw, Y2 = dh;
    if (!(x1 == 0 && y1 == 0 && x2 == 0 && y2 == 0)) {
        X1 = MAX(0, (int)lroundf(x1 * kx / factor)); Y1 = MAX(0, (int)lroundf(y1 * ky / factor));
        X2 = MIN(dw, (int)lroundf(x2 * kx / factor)); Y2 = MIN(dh, (int)lroundf(y2 * ky / factor));
    }

    int W = X2 - X1, H = Y2 - Y1;
    if (W < 8 || H < 8) { free(small); return 0; }

    // 灰度 + Sobel 梯度
    uint8_t *gray = (uint8_t *)malloc((size_t)W * H);
    double *gx = (double *)malloc(sizeof(double) * W * H);
    double *gy = (double *)malloc(sizeof(double) * W * H);
    double *mag = (double *)malloc(sizeof(double) * W * H);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
        const uint8_t *p = small + ((size_t)(Y1 + y) * dw + (X1 + x)) * 4;
        gray[y * W + x] = (uint8_t)((p[0] * 77 + p[1] * 150 + p[2] * 29) >> 8);
    }
    for (int y = 1; y < H - 1; y++) for (int x = 1; x < W - 1; x++) {
        double tl = gray[(y - 1) * W + x - 1], tc = gray[(y - 1) * W + x], tr = gray[(y - 1) * W + x + 1];
        double ml = gray[y * W + x - 1],                                 mr = gray[y * W + x + 1];
        double bl = gray[(y + 1) * W + x - 1], bc = gray[(y + 1) * W + x], br = gray[(y + 1) * W + x + 1];
        double sx = (tr + 2 * mr + br) - (tl + 2 * ml + bl);
        double sy = (bl + 2 * bc + br) - (tl + 2 * tc + tr);
        gx[y * W + x] = sx; gy[y * W + x] = sy;
        mag[y * W + x] = sqrt(sx * sx + sy * sy);
    }

    // 累加器（dp 降采样）
    int AW = (W + dp - 1) / dp, AH = (H + dp - 1) / dp;
    int *acc = (int *)calloc((size_t)AW * AH, sizeof(int));
    double thr = (double)(p1 > 0 ? p1 : 100);
    for (int y = 1; y < H - 1; y++) for (int x = 1; x < W - 1; x++) {
        double m = mag[y * W + x];
        if (m < thr) continue;
        double sx = gx[y * W + x], sy = gy[y * W + x];
        double len = sqrt(sx * sx + sy * sy) + 1e-6;
        double nx = sx / len, ny = sy / len;       // 指向圆心方向（梯度朝亮侧，圆心在暗侧取反）
        for (int r = minR / factor; r <= maxR / factor; r += 1) {
            int vx = (int)lroundf((double)x - nx * r), vy = (int)lroundf((double)y - ny * r);
            int ax = vx / dp, ay = vy / dp;
            if (ax >= 0 && ax < AW && ay >= 0 && ay < AH) acc[ay * AW + ax] += 1;
            int ux = (int)lroundf((double)x + nx * r), uy = (int)lroundf((double)y + ny * r);
            int bx = ux / dp, by = uy / dp;
            if (bx >= 0 && bx < AW && by >= 0 && by < AH) acc[by * AW + bx] += 1;
        }
    }

    // 找峰值（局部最大 + 阈值）
    int bestV = 0, bestX = 0, bestY = 0;
    int pthr = MAX(8, (maxR / factor - minR / factor));   // 至少跨过部分半径才有意义
    for (int y = 1; y < AH - 1; y++) for (int x = 1; x < AW - 1; x++) {
        int v = acc[y * AW + x];
        if (v < pthr) continue;
        int local = 1;
        for (int dy = -1; dy <= 1 && local; dy++) for (int dx = -1; dx <= 1; dx++)
            if (acc[(y + dy) * AW + (x + dx)] > v) { local = 0; break; }
        if (local && v > bestV) { bestV = v; bestX = x * dp + dp / 2; bestY = y * dp + dp / 2; }
    }

    free(gray); free(gx); free(gy); free(mag); free(acc); free(small);
    if (bestV < pthr) return 0;

    // 估半径：在最佳圆心处扫描 r，数环上边缘一致的点，取峰值
    int bestR = (minR + maxR) / 2;  // 默认中值，缩帧坐标
    // 以缩帧半径空间估算（不除以 factor，因 W/H 已是缩帧）
    int rminS = minR / factor, rmaxS = maxR / factor;
    if (rminS < 1) rminS = 1;
    int bestRscore = -1;
    for (int r = rminS; r <= rmaxS; r++) {
        int cnt = 0, total = 0;
        const int A = 24;
        for (int k = 0; k < A; k++) {
            double ang = 2 * M_PI * k / A;
            int px = bestX + (int)lroundf(cos(ang) * r);
            int py = bestY + (int)lroundf(sin(ang) * r);
            if (px < 0 || px >= W || py < 0 || py >= H) continue;
            total++;
            // 环上点应是强边缘
            if (mag[py * W + px] >= thr * 0.6) cnt++;
        }
        if (total && cnt * 100 / total > bestRscore) { bestRscore = cnt * 100 / total; bestR = r; }
    }

    // 缩帧 -> 逻辑点
    *outCx = (int)lroundf(bestX * (double)factor / kx);
    *outCy = (int)lroundf(bestY * (double)factor / ky);
    *outR  = (int)lroundf(bestR * (double)factor / ((kx + ky) / 2));
    return 1;
}
