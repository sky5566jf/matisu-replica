// MatisuAuto — 设备端图色查找实现
// 颜色串格式（与原版/PC 桥一致）："BBGGRR" 或 "BBGGRR-DRDGDB"（偏色），| 分隔多色；
// 多点串："x|y|BBGGRR[-DRDGDB],x|y|...,..."
#import "ColorFind.h"
#import "ScreenShot.h"
#import <UIKit/UIKit.h>

// 颜色条目（分解到通道；dr/dg/db 为偏色容差，0 表示用 sim 容差）
typedef struct { int r, g, b, dr, dg, db; } MAColorSpec;

static int hexVal(const char *s, int len) {
    int v = 0;
    for (int i = 0; i < len; i++) {
        char c = s[i]; v <<= 4;
        if (c >= '0' && c <= '9') v |= c - '0';
        else if (c >= 'a' && c <= 'f') v |= c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') v |= c - 'A' + 10;
    }
    return v;
}

/// 解析单色 "BBGGRR[-DRDGDB]"，返回 NO 表示格式错
static BOOL parseOne(NSString *seg, MAColorSpec *out) {
    NSString *s = [seg stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([s hasPrefix:@"0x"] || [s hasPrefix:@"0X"]) s = [s substringFromIndex:2];
    NSArray *parts = [s componentsSeparatedByString:@"-"];
    if (parts[0].length != 6) return NO;
    const char *c = parts[0].UTF8String;
    int v = hexVal(c, 6);
    out->b = (v >> 16) & 0xFF; out->g = (v >> 8) & 0xFF; out->r = v & 0xFF;   // BBGGRR
    out->dr = out->dg = out->db = 0;
    if (parts.count > 1 && [parts[1] length] == 6) {
        const char *d = [parts[1] UTF8String];
        out->dr = hexVal(d, 2); out->dg = hexVal(d + 2, 2); out->db = hexVal(d + 4, 2);
    }
    return YES;
}

#define MA_MAX_COLORS 16
static int parseMulti(NSString *spec, MAColorSpec *out) {
    NSArray *segs = [spec componentsSeparatedByString:@"|"];
    int n = 0;
    for (NSString *seg in segs) {
        if (n >= MA_MAX_COLORS) break;
        if (parseOne(seg, &out[n])) n++;
    }
    return n;
}

static inline BOOL pxMatch(const uint8_t *p, const MAColorSpec *cs, int n, int tol) {
    for (int i = 0; i < n; i++) {
        int db = abs(p[0] - cs[i].b), dg = abs(p[1] - cs[i].g), dr = abs(p[2] - cs[i].r);
        int tr = cs[i].dr > tol ? cs[i].dr : tol;
        int tg = cs[i].dg > tol ? cs[i].dg : tol;
        int tb = cs[i].db > tol ? cs[i].db : tol;
        if (db <= tb && dg <= tg && dr <= tr) return YES;
    }
    return NO;
}

// 逻辑点 -> 物理像素换算参数
static void maScale(float *sx, float *sy) {
    __block CGSize lb = CGSizeZero;
    void (^rd)(void) = ^{ lb = [UIScreen mainScreen].bounds.size; };
    if ([NSThread isMainThread]) rd();
    else dispatch_sync(dispatch_get_main_queue(), rd);
    int sw = 0, sh = 0;
    // 物理尺寸由调用方 lock 后提供；此处只算比例，调用方乘 sw/sh
    *sx = lb.width > 0 ? (float)lb.width : 320.0f;
    *sy = lb.height > 0 ? (float)lb.height : 568.0f;
    (void)sw; (void)sh;
}

// 上下文：一次 lock 供多次扫描
typedef struct {
    const uint8_t *base;
    int w, h, bpr;
    float lw, lh;      // 逻辑尺寸
    float kx, ky;      // 逻辑->物理比例
} MACapCtx;

static BOOL capBegin(MACapCtx *c) {
    c->base = MatisuSurfaceLockRead(&c->w, &c->h, &c->bpr);
    if (!c->base) return NO;
    maScale(&c->lw, &c->lh);
    c->kx = (float)c->w / c->lw;
    c->ky = (float)c->h / c->lh;
    return YES;
}
static void capEnd(MACapCtx *c) { MatisuSurfaceUnlockRead(); }

static inline int toPxX(MACapCtx *c, int x) { return (int)lroundf(x * c->kx); }
static inline int toPxY(MACapCtx *c, int y) { return (int)lroundf(y * c->ky); }
static inline int toLgX(MACapCtx *c, int x) { return (int)lroundf(x / c->kx); }
static inline int toLgY(MACapCtx *c, int y) { return (int)lroundf(y / c->ky); }

static void normRegion(MACapCtx *c, int *x1, int *y1, int *x2, int *y2) {
    if (*x1 == 0 && *y1 == 0 && *x2 == 0 && *y2 == 0) { *x1 = 0; *y1 = 0; *x2 = c->w; *y2 = c->h; return; }
    int X1 = toPxX(c, *x1), Y1 = toPxY(c, *y1), X2 = toPxX(c, *x2), Y2 = toPxY(c, *y2);
    if (X1 < 0) X1 = 0; if (Y1 < 0) Y1 = 0;
    if (X2 > c->w) X2 = c->w; if (Y2 > c->h) Y2 = c->h;
    *x1 = X1; *y1 = Y1; *x2 = X2; *y2 = Y2;
}

int MatisuFindColor(int x1, int y1, int x2, int y2, NSString *colorSpec, int dir, double sim, int *outX, int *outY) {
    MAColorSpec cs[MA_MAX_COLORS];
    int n = parseMulti(colorSpec, cs);
    if (n <= 0) return 0;
    int tol = (int)((1.0 - (sim <= 0 ? 0.9 : (sim > 1 ? 1 : sim))) * 255.0 + 0.5);

    MACapCtx c;
    if (!capBegin(&c)) return 0;
    normRegion(&c, &x1, &y1, &x2, &y2);

    int bestX = -1, bestY = -1;
    if (dir == 0) {
        // 默认：左上扫描序首个命中
        for (int y = y1; y < y2 && bestX < 0; y++)
            for (int x = x1; x < x2; x++)
                if (pxMatch(c.base + (size_t)y * c.bpr + (size_t)x * 4, cs, n, tol)) { bestX = x; bestY = y; break; }
    } else if (dir == 2 || dir == 3) {
        // 2=从右下(y降x降) 3=从左下(y降x升)
        int bestScore = -1;
        for (int y = y1; y < y2; y++) for (int x = x1; x < x2; x++) {
            if (!pxMatch(c.base + (size_t)y * c.bpr + (size_t)x * 4, cs, n, tol)) continue;
            int score = (dir == 2) ? (y * c.w + x) : (y * c.w + (c.w - x));
            if (score > bestScore) { bestScore = score; bestX = x; bestY = y; }
        }
    } else if (dir == 4) {
        // 4=从右上(y升x降)
        int bestScore = -1;
        for (int y = y1; y < y2; y++) for (int x = x1; x < x2; x++) {
            if (!pxMatch(c.base + (size_t)y * c.bpr + (size_t)x * 4, cs, n, tol)) continue;
            int score = ((c.h - y) * c.w + x);
            if (score > bestScore) { bestScore = score; bestX = x; bestY = y; }
        }
    } else {
        // 1=离屏幕中心最近
        double bestD = 1e18;
        double cx0 = c.w / 2.0, cy0 = c.h / 2.0;
        for (int y = y1; y < y2; y++) for (int x = x1; x < x2; x++) {
            if (!pxMatch(c.base + (size_t)y * c.bpr + (size_t)x * 4, cs, n, tol)) continue;
            double d = (x - cx0) * (x - cx0) + (y - cy0) * (y - cy0);
            if (d < bestD) { bestD = d; bestX = x; bestY = y; }
        }
    }
    capEnd(&c);
    if (bestX < 0) return 0;
    if (outX) *outX = toLgX(&c, bestX);
    if (outY) *outY = toLgY(&c, bestY);
    return 1;
}

int MatisuCmpColor(int x, int y, NSString *colorSpec, double sim) {
    MAColorSpec cs[MA_MAX_COLORS];
    int n = parseMulti(colorSpec, cs);
    if (n <= 0) return 0;
    int tol = (int)((1.0 - (sim <= 0 ? 0.9 : (sim > 1 ? 1 : sim))) * 255.0 + 0.5);
    MACapCtx c;
    if (!capBegin(&c)) return 0;
    int px = toPxX(&c, x), py = toPxY(&c, y);
    int ret = 0;
    if (px >= 0 && py >= 0 && px < c.w && py < c.h)
        ret = pxMatch(c.base + (size_t)py * c.bpr + (size_t)px * 4, cs, n, tol) ? 1 : 0;
    capEnd(&c);
    return ret;
}

int MatisuCmpColorEx(NSString *multiSpec, double sim) {
    int tol = (int)((1.0 - (sim <= 0 ? 0.9 : (sim > 1 ? 1 : sim))) * 255.0 + 0.5);
    NSArray *pts = [multiSpec componentsSeparatedByString:@","];
    if (!pts.count) return 0;
    MACapCtx c;
    if (!capBegin(&c)) return 0;
    int ret = 1;
    for (NSString *pt in pts) {
        NSArray *a = [pt componentsSeparatedByString:@"|"];
        if (a.count < 3) { ret = 0; break; }
        int px = toPxX(&c, [a[0] intValue]), py = toPxY(&c, [a[1] intValue]);
        MAColorSpec cs[MA_MAX_COLORS];
        int n = parseMulti([a subarrayWithRange:NSMakeRange(2, a.count - 2)][0], cs);
        if (n <= 0 || px < 0 || py < 0 || px >= c.w || py >= c.h ||
            !pxMatch(c.base + (size_t)py * c.bpr + (size_t)px * 4, cs, n, tol)) { ret = 0; break; }
    }
    capEnd(&c);
    return ret;
}

int MatisuGetColorNum(int x1, int y1, int x2, int y2, NSString *colorSpec, double sim) {
    MAColorSpec cs[MA_MAX_COLORS];
    int n = parseMulti(colorSpec, cs);
    if (n <= 0) return 0;
    int tol = (int)((1.0 - (sim <= 0 ? 0.9 : (sim > 1 ? 1 : sim))) * 255.0 + 0.5);
    MACapCtx c;
    if (!capBegin(&c)) return 0;
    normRegion(&c, &x1, &y1, &x2, &y2);
    int cnt = 0;
    for (int y = y1; y < y2; y++) for (int x = x1; x < x2; x++)
        if (pxMatch(c.base + (size_t)y * c.bpr + (size_t)x * 4, cs, n, tol)) cnt++;
    capEnd(&c);
    return cnt;
}
