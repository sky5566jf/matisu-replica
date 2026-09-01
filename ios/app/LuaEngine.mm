// MatisuAuto — 设备端 Lua 引擎实现（Phase 1）
//
// 注册的 Lua 全局函数（与 PC 端 core.lua 契约同名）：
//   print(...)                        输出收集回传
//   tap(x,y) longTap(x,y,sec) swipe(x1,y1,x2,y2,dur)
//   touchDown(f,x,y) touchMove(f,x,y) touchUp(f,x,y)
//   keyPress(name) inputText(ascii)
//   getDisplaySize() -> w,h           逻辑点（显示缩放机=真实 UI 空间）
//   getPixelColor(x,y[,type]) -> 0xRRGGBB（type=1 返回整数）
//   sleep(s) mSleep(ms)
#import "LuaEngine.h"
#import "TouchInject.h"
#import "ScreenShot.h"
#import "ColorFind.h"
#import "PicFind.h"
#import "SysUtil.h"
#import "OcrEngine.h"
#import <UIKit/UIKit.h>
#import <unistd.h>
#import <stdlib.h>

// lua 官方头无 extern "C" 守卫（lua.hpp 在 etc/ 未 vendor），C++ 侧自行包裹
extern "C" {
#import "lua/lua.h"
#import "lua/lauxlib.h"
#import "lua/lualib.h"
}

static void registerFns(lua_State *L, lua_CFunction printFn);

// 输出收集（每次 run 挂在 lua_State 的 registry 上）
#define MA_OUT_KEY "matisu_output"

static NSMutableString *maOut(lua_State *L) {
    lua_getfield(L, LUA_REGISTRYINDEX, MA_OUT_KEY);
    NSMutableString *s = (__bridge NSMutableString *)lua_touserdata(L, -1);
    lua_pop(L, 1);
    return s;
}

static int l_print(lua_State *L) {
    NSMutableString *out = maOut(L);
    int n = lua_gettop(L);
    lua_getglobal(L, "tostring");
    for (int i = 1; i <= n; i++) {
        lua_pushvalue(L, -1);
        lua_pushvalue(L, i);
        lua_call(L, 1, 1);
        const char *s = lua_tostring(L, -1);
        if (i > 1) [out appendString:@"\t"];
        if (s) [out appendString:[NSString stringWithUTF8String:s] ?: @"?"];
        lua_pop(L, 1);
    }
    [out appendString:@"\n"];
    return 0;
}

static int l_tap(lua_State *L) {
    MatisuTouchTap((float)luaL_checknumber(L, 1), (float)luaL_checknumber(L, 2));
    return 0;
}
static int l_longTap(lua_State *L) {
    float x = (float)luaL_checknumber(L, 1), y = (float)luaL_checknumber(L, 2);
    double sec = luaL_optnumber(L, 3, 1.0);
    MatisuTouchDown(0, x, y);
    usleep((useconds_t)(sec * 1000000));
    MatisuTouchUp(0, x, y);
    return 0;
}
static int l_swipe(lua_State *L) {
    MatisuTouchSwipe((float)luaL_checknumber(L, 1), (float)luaL_checknumber(L, 2),
                     (float)luaL_checknumber(L, 3), (float)luaL_checknumber(L, 4),
                     luaL_optnumber(L, 5, 0.2));
    return 0;
}
static int l_touchDown(lua_State *L) {
    MatisuTouchDown((int)luaL_checkinteger(L, 1), (float)luaL_checknumber(L, 2), (float)luaL_checknumber(L, 3));
    return 0;
}
static int l_touchMove(lua_State *L) {
    MatisuTouchMove((int)luaL_checkinteger(L, 1), (float)luaL_checknumber(L, 2), (float)luaL_checknumber(L, 3));
    return 0;
}
static int l_touchUp(lua_State *L) {
    MatisuTouchUp((int)luaL_checkinteger(L, 1), (float)luaL_checknumber(L, 2), (float)luaL_checknumber(L, 3));
    return 0;
}
static int l_keyPress(lua_State *L) {
    MatisuKeyPressName(luaL_checkstring(L, 1));
    return 0;
}
static int l_inputText(lua_State *L) {
    MatisuTypeText(luaL_checkstring(L, 1));
    return 0;
}

static void maScreenSize(float *w, float *h) {
    __block CGSize b = CGSizeZero;
    void (^rd)(void) = ^{ b = [UIScreen mainScreen].bounds.size; };
    if ([NSThread isMainThread]) rd();
    else dispatch_sync(dispatch_get_main_queue(), rd);
    *w = (float)b.width; *h = (float)b.height;
}

static int l_getDisplaySize(lua_State *L) {
    float w = 0, h = 0;
    maScreenSize(&w, &h);
    lua_pushinteger(L, (lua_Integer)lroundf(w));
    lua_pushinteger(L, (lua_Integer)lroundf(h));
    return 2;
}

static int l_getPixelColor(lua_State *L) {
    int x = (int)luaL_checkinteger(L, 1), y = (int)luaL_checkinteger(L, 2);
    int type = (int)luaL_optinteger(L, 3, 0);
    int c = MatisuCapturePixel(x, y);
    if (c < 0) { lua_pushnil(L); return 1; }
    if (type == 1) {
        lua_pushinteger(L, c);
    } else {
        char buf[8];
        snprintf(buf, sizeof(buf), "%06X", (unsigned)c & 0xFFFFFF);
        lua_pushstring(L, buf);
    }
    return 1;
}

static int l_sleep(lua_State *L) {
    usleep((useconds_t)(luaL_checknumber(L, 1) * 1000000));
    return 0;
}
static int l_mSleep(lua_State *L) {
    usleep((useconds_t)(luaL_checkinteger(L, 1) * 1000));
    return 0;
}

static int l_findColor(lua_State *L) {
    int ox = -1, oy = -1;
    int hit = MatisuFindColor((int)luaL_optinteger(L, 1, 0), (int)luaL_optinteger(L, 2, 0),
                              (int)luaL_optinteger(L, 3, 0), (int)luaL_optinteger(L, 4, 0),
                              [NSString stringWithUTF8String:luaL_checkstring(L, 5)],
                              (int)luaL_optinteger(L, 6, 0), luaL_optnumber(L, 7, 0.9), &ox, &oy);
    lua_pushinteger(L, hit ? ox : -1);
    lua_pushinteger(L, hit ? oy : -1);
    return 2;
}
static int l_cmpColor(lua_State *L) {
    int r = MatisuCmpColor((int)luaL_checkinteger(L, 1), (int)luaL_checkinteger(L, 2),
                           [NSString stringWithUTF8String:luaL_checkstring(L, 3)], luaL_optnumber(L, 4, 0.9));
    lua_pushinteger(L, r);
    return 1;
}
static int l_cmpColorEx(lua_State *L) {
    int r = MatisuCmpColorEx([NSString stringWithUTF8String:luaL_checkstring(L, 1)], luaL_optnumber(L, 2, 0.9));
    lua_pushinteger(L, r);
    return 1;
}
static int l_getColorNum(lua_State *L) {
    int n = MatisuGetColorNum((int)luaL_optinteger(L, 1, 0), (int)luaL_optinteger(L, 2, 0),
                              (int)luaL_optinteger(L, 3, 0), (int)luaL_optinteger(L, 4, 0),
                              [NSString stringWithUTF8String:luaL_checkstring(L, 5)], luaL_optnumber(L, 6, 0.9));
    lua_pushinteger(L, n);
    return 1;
}
static int l_snapShot(lua_State *L) {
    // snapShot(path[, x1,y1,x2,y2])：PNG 存设备路径（无区域=全屏）
    NSString *path = [NSString stringWithUTF8String:luaL_checkstring(L, 1)];
    NSData *png = nil;
    if (lua_gettop(L) >= 5) {
        png = MatisuCapturePNGRegion((int)luaL_checkinteger(L, 2), (int)luaL_checkinteger(L, 3),
                                     (int)luaL_checkinteger(L, 4), (int)luaL_checkinteger(L, 5));
    } else {
        png = MatisuCapturePNG();
    }
    if (png && [png writeToFile:path atomically:YES]) {
        lua_pushstring(L, path.UTF8String);
    } else {
        lua_pushnil(L);
    }
    return 1;
}
static int l_findPic(lua_State *L) {
    int ox = -1, oy = -1;
    int hit = MatisuFindPic((int)luaL_optinteger(L, 1, 0), (int)luaL_optinteger(L, 2, 0),
                            (int)luaL_optinteger(L, 3, 0), (int)luaL_optinteger(L, 4, 0),
                            [NSString stringWithUTF8String:luaL_checkstring(L, 5)],
                            luaL_optnumber(L, 6, 0.9), &ox, &oy);
    lua_pushinteger(L, hit ? ox : -1);
    lua_pushinteger(L, hit ? oy : -1);
    return 2;
}
static int l_findPicEx(lua_State *L) {
    int ox = -1, oy = -1;
    int hit = MatisuFindPicEx((int)luaL_optinteger(L, 1, 0), (int)luaL_optinteger(L, 2, 0),
                              (int)luaL_optinteger(L, 3, 0), (int)luaL_optinteger(L, 4, 0),
                              [NSString stringWithUTF8String:luaL_checkstring(L, 5)],
                              luaL_optnumber(L, 6, 0.9), &ox, &oy);
    lua_pushinteger(L, hit ? ox : -1);
    lua_pushinteger(L, hit ? oy : -1);
    return 2;
}
static int l_findPicAllPoint(lua_State *L) {
    int *xy = NULL; int n = 0;
    int ret = MatisuFindPicAllPoint((int)luaL_optinteger(L, 1, 0), (int)luaL_optinteger(L, 2, 0),
                                    (int)luaL_optinteger(L, 3, 0), (int)luaL_optinteger(L, 4, 0),
                                    [NSString stringWithUTF8String:luaL_checkstring(L, 5)],
                                    luaL_optnumber(L, 6, 0.9), (int)luaL_optinteger(L, 7, 0),
                                    &xy, &n);
    if (!ret || n == 0) { free(xy); lua_pushnil(L); return 1; }
    lua_newtable(L);
    for (int i = 0; i < n; i++) {
        lua_newtable(L);
        lua_pushinteger(L, xy[i * 2]);     lua_rawseti(L, -2, 1);
        lua_pushinteger(L, xy[i * 2 + 1]); lua_rawseti(L, -2, 2);
        lua_rawseti(L, -2, i + 1);
    }
    free(xy);
    return 1;
}
static int l_findCircle(lua_State *L) {
    int cx = -1, cy = -1, r = -1;
    int hit = MatisuFindCircle((int)luaL_optinteger(L, 1, 0), (int)luaL_optinteger(L, 2, 0),
                               (int)luaL_optinteger(L, 3, 0), (int)luaL_optinteger(L, 4, 0),
                               (int)luaL_optinteger(L, 5, 1), (int)luaL_optinteger(L, 6, 20),
                               (int)luaL_optinteger(L, 7, 100), (int)luaL_optinteger(L, 8, 30),
                               (int)luaL_optinteger(L, 9, 5), (int)luaL_optinteger(L, 10, 200),
                               &cx, &cy, &r);
    lua_pushinteger(L, hit ? cx : -1);
    lua_pushinteger(L, hit ? cy : -1);
    lua_pushinteger(L, hit ? r : -1);
    return 3;
}
static int l_findMultiColor(lua_State *L) {
    int ox = -1, oy = -1;
    int hit = MatisuFindMultiColor((int)luaL_optinteger(L, 1, 0), (int)luaL_optinteger(L, 2, 0),
                                   (int)luaL_optinteger(L, 3, 0), (int)luaL_optinteger(L, 4, 0),
                                   [NSString stringWithUTF8String:luaL_checkstring(L, 5)],
                                   [NSString stringWithUTF8String:luaL_optstring(L, 6, "")],
                                   (int)luaL_optinteger(L, 7, 0), luaL_optnumber(L, 8, 0.9), &ox, &oy);
    lua_pushinteger(L, hit ? ox : -1);
    lua_pushinteger(L, hit ? oy : -1);
    return 2;
}

// ---------------- *T 变体：table 打包参数（原版 findColorT / cmpColorExT 等） ----------------
// 兼容两种写法：具名字段 {x1=,y1=,x2=,y2=,color=,dir=,sim=} 或数组下标 {x1,y1,x2,y2,...}。
// 先按具名取、取不到再按下标兜底，两种脚本风格都能跑。
static void maTblPush(lua_State *L, int idx, const char *key, int nth) {
    lua_pushvalue(L, idx);
    if (key) {
        lua_getfield(L, -1, key);
        // 具名取不到(nil)按下标兜底——数组形式 {x1,y1,...} 的脚本也能跑
        if (nth > 0 && lua_isnil(L, -1)) { lua_pop(L, 1); lua_rawgeti(L, -1, nth); }
    } else {
        lua_rawgeti(L, -1, nth);
    }
    lua_remove(L, -2);   // 弹掉 table，栈顶留下取到的值（没取到就是 nil）
}
static lua_Integer maTblInt(lua_State *L, int idx, const char *key, int nth, lua_Integer def) {
    maTblPush(L, idx, key, nth);
    lua_Integer v = luaL_optinteger(L, -1, def);
    lua_pop(L, 1);
    return v;
}
static double maTblNum(lua_State *L, int idx, const char *key, int nth, double def) {
    maTblPush(L, idx, key, nth);
    double v = luaL_optnumber(L, -1, def);
    lua_pop(L, 1);
    return v;
}
static NSString *maTblStr(lua_State *L, int idx, const char *key, int nth, const char *def) {
    maTblPush(L, idx, key, nth);
    const char *s = luaL_optstring(L, -1, def);
    NSString *r = s ? [NSString stringWithUTF8String:s] : @"";
    lua_pop(L, 1);
    return r;
}

static int l_findColorT(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    int ox = -1, oy = -1;
    int hit = MatisuFindColor((int)maTblInt(L, 1, "x1", 1, 0), (int)maTblInt(L, 1, "y1", 2, 0),
                              (int)maTblInt(L, 1, "x2", 3, 0), (int)maTblInt(L, 1, "y2", 4, 0),
                              maTblStr(L, 1, "color", 5, ""),
                              (int)maTblInt(L, 1, "dir", 6, 0), maTblNum(L, 1, "sim", 7, 0.9),
                              &ox, &oy);
    lua_pushinteger(L, hit ? ox : -1);
    lua_pushinteger(L, hit ? oy : -1);
    return 2;
}
static int l_findMultiColorT(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    int ox = -1, oy = -1;
    int hit = MatisuFindMultiColor((int)maTblInt(L, 1, "x1", 1, 0), (int)maTblInt(L, 1, "y1", 2, 0),
                                   (int)maTblInt(L, 1, "x2", 3, 0), (int)maTblInt(L, 1, "y2", 4, 0),
                                   maTblStr(L, 1, "color", 5, ""),
                                   maTblStr(L, 1, "offset", 6, ""),
                                   (int)maTblInt(L, 1, "dir", 7, 0), maTblNum(L, 1, "sim", 8, 0.9),
                                   &ox, &oy);
    lua_pushinteger(L, hit ? ox : -1);
    lua_pushinteger(L, hit ? oy : -1);
    return 2;
}
static int l_findMultiColorAllT(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    NSString *r = MatisuFindMultiColorAll((int)maTblInt(L, 1, "x1", 1, 0), (int)maTblInt(L, 1, "y1", 2, 0),
                                          (int)maTblInt(L, 1, "x2", 3, 0), (int)maTblInt(L, 1, "y2", 4, 0),
                                          maTblStr(L, 1, "color", 5, ""),
                                          maTblStr(L, 1, "offset", 6, ""),
                                          maTblNum(L, 1, "sim", 7, 0.9));
    lua_pushstring(L, r.UTF8String);
    return 1;
}
static int l_cmpColorExT(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    // 入参三选一：spec 串（具名 spec / 数组 [1]），或 x+y+color 由这里拼成 "x|y|color"。
    // 注意用 lua_type 判断而不是直接 optstring —— 数组形式下 [1] 可能是数字 x，
    // 直接转字符串会把坐标误当成 spec。
    NSString *spec = @"";
    maTblPush(L, 1, "spec", 0);
    if (lua_type(L, -1) == LUA_TSTRING) spec = [NSString stringWithUTF8String:lua_tostring(L, -1)];
    lua_pop(L, 1);
    if (!spec.length) {
        maTblPush(L, 1, NULL, 1);
        if (lua_type(L, -1) == LUA_TSTRING) spec = [NSString stringWithUTF8String:lua_tostring(L, -1)];
        lua_pop(L, 1);
    }
    if (!spec.length) {
        spec = [NSString stringWithFormat:@"%@|%@|%@",
                maTblStr(L, 1, "x", 1, "0"),
                maTblStr(L, 1, "y", 2, "0"),
                maTblStr(L, 1, "color", 3, "")];
    }
    // sim：具名 sim -> 数组 [2] -> 数组 [4]
    double sim = 0.9;
    maTblPush(L, 1, "sim", 0);
    if (!lua_isnil(L, -1)) sim = luaL_optnumber(L, -1, 0.9);
    lua_pop(L, 1);
    if (sim == 0.9) {
        maTblPush(L, 1, NULL, 2);
        if (lua_type(L, -1) == LUA_TNUMBER) sim = lua_tonumber(L, -1);
        lua_pop(L, 1);
        maTblPush(L, 1, NULL, 4);
        if (lua_type(L, -1) == LUA_TNUMBER) sim = lua_tonumber(L, -1);
        lua_pop(L, 1);
    }
    int r = MatisuCmpColorEx(spec, sim);
    lua_pushinteger(L, r);
    return 1;
}

// ---------------- 颜色工具 ----------------
// colorDiff(c1,c2)：两色（0xRRGGBB）三通道差的绝对值和，0=完全相同，上限 765
static int l_colorDiff(lua_State *L) {
    unsigned int c1 = (unsigned int)luaL_checkinteger(L, 1);
    unsigned int c2 = (unsigned int)luaL_checkinteger(L, 2);
    int r1 = (c1 >> 16) & 0xFF, g1 = (c1 >> 8) & 0xFF, b1 = c1 & 0xFF;
    int r2 = (c2 >> 16) & 0xFF, g2 = (c2 >> 8) & 0xFF, b2 = c2 & 0xFF;
    lua_pushinteger(L, abs(r1 - r2) + abs(g1 - g2) + abs(b1 - b2));
    return 1;
}
// colorToRGB(c) -> r,g,b
static int l_colorToRGB(lua_State *L) {
    unsigned int c = (unsigned int)luaL_checkinteger(L, 1);
    lua_pushinteger(L, (c >> 16) & 0xFF);
    lua_pushinteger(L, (c >> 8) & 0xFF);
    lua_pushinteger(L, c & 0xFF);
    return 3;
}

// ---------------- 网络 / 编码 / jsonLib ----------------
#import <CommonCrypto/CommonCrypto.h>

/// 同步 HTTP（daemon 后台线程调用；@autoreleasepool 防泄漏）
static void maHttp(NSString *method, NSString *urlStr, NSData *body, double timeout,
                   NSData **outData, long *outCode, NSString **outErr) {
    @autoreleasepool {
        __block NSData *respData = nil;
        __block long code = 0;
        __block NSString *errStr = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:timeout];
        req.HTTPMethod = method;
        if (body) req.HTTPBody = body;
        NSURLSessionDataTask *t = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                                  completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            respData = d;
            if ([r isKindOfClass:[NSHTTPURLResponse class]]) code = [(NSHTTPURLResponse *)r statusCode];
            if (e) errStr = e.localizedDescription;
            dispatch_semaphore_signal(sem);
        }];
        [t resume];
        long wait = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
        if (wait != 0) { [t cancel]; errStr = @"timeout"; }
        *outData = respData;
        *outCode = code;
        *outErr = errStr;
    }
}

static int l_httpGet(lua_State *L) {
    NSString *url = [NSString stringWithUTF8String:luaL_checkstring(L, 1)];
    double timeout = luaL_optnumber(L, 2, 30);
    NSData *d = nil; long code = 0; NSString *err = nil;
    maHttp(@"GET", url, nil, timeout, &d, &code, &err);
    if (!d) { lua_pushnil(L); lua_pushinteger(L, 0); return 2; }
    lua_pushlstring(L, (const char *)d.bytes, (size_t)d.length);
    lua_pushinteger(L, code);
    return 2;
}
static int l_httpPost(lua_State *L) {
    NSString *url = [NSString stringWithUTF8String:luaL_checkstring(L, 1)];
    size_t blen = 0;
    const char *bd = luaL_optlstring(L, 2, "", &blen);
    double timeout = luaL_optnumber(L, 3, 30);
    NSData *d = nil; long code = 0; NSString *err = nil;
    maHttp(@"POST", url, [NSData dataWithBytes:bd length:blen], timeout, &d, &code, &err);
    if (!d) { lua_pushnil(L); lua_pushinteger(L, 0); return 2; }
    lua_pushlstring(L, (const char *)d.bytes, (size_t)d.length);
    lua_pushinteger(L, code);
    return 2;
}
/// downloadFile(url, path[, timeout]) -> true/false
static int l_download(lua_State *L) {
    NSString *url = [NSString stringWithUTF8String:luaL_checkstring(L, 1)];
    NSString *path = [NSString stringWithUTF8String:luaL_checkstring(L, 2)];
    double timeout = luaL_optnumber(L, 3, 60);
    NSData *d = nil; long code = 0; NSString *err = nil;
    maHttp(@"GET", url, nil, timeout, &d, &code, &err);
    if (!d) { lua_pushboolean(L, 0); return 1; }
    NSError *werr = nil;
    BOOL ok = [d writeToFile:path options:NSDataWritingAtomic error:&werr];
    if (!ok) NSLog(@"[MatisuAuto] downloadFile 写盘失败 %@", werr.localizedDescription);
    lua_pushboolean(L, ok);
    return 1;
}

static int l_MD5(lua_State *L) {
    size_t len = 0;
    const char *s = luaL_checklstring(L, 1, &len);
    unsigned char dig[CC_MD5_DIGEST_LENGTH];
    CC_MD5(s, (CC_LONG)len, dig);
    char hex[33];
    for (int i = 0; i < 16; i++) snprintf(hex + i * 2, 3, "%02x", dig[i]);
    lua_pushstring(L, hex);
    return 1;
}
static int l_sha1(lua_State *L) {
    size_t len = 0;
    const char *s = luaL_checklstring(L, 1, &len);
    unsigned char dig[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(s, (CC_LONG)len, dig);
    char hex[41];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) snprintf(hex + i * 2, 3, "%02x", dig[i]);
    lua_pushstring(L, hex);
    return 1;
}
static int l_encodeBase64(lua_State *L) {
    size_t len = 0;
    const char *s = luaL_checklstring(L, 1, &len);
    NSString *b64 = [[NSData dataWithBytes:s length:len] base64EncodedStringWithOptions:0];
    lua_pushstring(L, b64.UTF8String);
    return 1;
}
static int l_decodeBase64(lua_State *L) {
    NSString *b64 = [NSString stringWithUTF8String:luaL_checkstring(L, 1)];
    NSData *d = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    if (!d) { lua_pushnil(L); return 1; }
    lua_pushlstring(L, (const char *)d.bytes, (size_t)d.length);
    return 1;
}

// Lua 值 <-> NSObject（jsonLib 用，递归）
static id maLuaToObj(lua_State *L, int idx) {
    int t = lua_type(L, idx);
    switch (t) {
        case LUA_TNIL: return [NSNull null];
        case LUA_TBOOLEAN: return @(lua_toboolean(L, idx) ? YES : NO);
        case LUA_TNUMBER: return @(lua_tonumber(L, idx));
        case LUA_TSTRING: {
            size_t n = 0; const char *s = lua_tolstring(L, idx, &n);
            return [[NSString alloc] initWithBytes:s length:n encoding:NSUTF8StringEncoding] ?: @"";
        }
        case LUA_TTABLE: {
            // 连续整数键 1..n => 数组，否则字典
            lua_Integer maxn = 0, cnt = 0;
            BOOL isArr = YES;
            lua_pushnil(L);
            while (lua_next(L, idx < 0 ? idx - 1 : idx)) {
                cnt++;
                if (lua_type(L, -2) != LUA_TNUMBER) isArr = NO;
                else { lua_Integer k = lua_tointeger(L, -2); if (k > maxn) maxn = k; }
                lua_pop(L, 1);
            }
            // 空表按 cjson/原版语义编成 {}（对象），不是 []
            if (isArr && cnt > 0 && maxn == cnt) {
                NSMutableArray *arr = [NSMutableArray arrayWithCapacity:cnt];
                for (lua_Integer i = 1; i <= maxn; i++) {
                    lua_geti(L, idx, i);
                    [arr addObject:maLuaToObj(L, -1)];
                    lua_pop(L, 1);
                }
                return arr;
            }
            NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithCapacity:cnt];
            lua_pushnil(L);
            while (lua_next(L, idx < 0 ? idx - 1 : idx)) {
                NSString *k = nil;
                if (lua_type(L, -2) == LUA_TSTRING) k = [NSString stringWithUTF8String:lua_tostring(L, -2)];
                else if (lua_type(L, -2) == LUA_TNUMBER) k = [@(lua_tonumber(L, -2)) stringValue];
                if (k) dict[k] = maLuaToObj(L, -1);
                lua_pop(L, 1);
            }
            return dict;
        }
        default: return [NSNull null];
    }
}
static void maObjToLua(lua_State *L, id obj) {
    if (!obj || [obj isKindOfClass:[NSNull class]]) { lua_pushnil(L); return; }
    if ([obj isKindOfClass:[NSNumber class]]) {
        const char *t = [obj objCType];
        if (!strcmp(t, @encode(BOOL)) || !strcmp(t, @encode(char))) lua_pushboolean(L, [obj boolValue]);
        else lua_pushnumber(L, [obj doubleValue]);
        return;
    }
    if ([obj isKindOfClass:[NSString class]]) {
        const char *s = [(NSString *)obj UTF8String];
        lua_pushstring(L, s ? s : "");
        return;
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        NSArray *a = (NSArray *)obj;
        lua_createtable(L, (int)a.count, 0);
        [a enumerateObjectsUsingBlock:^(id v, NSUInteger i, BOOL *stop) {
            maObjToLua(L, v);
            lua_seti(L, -2, (lua_Integer)i + 1);
        }];
        return;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)obj;
        lua_createtable(L, 0, (int)d.count);
        [d enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
            maObjToLua(L, k);
            maObjToLua(L, v);
            lua_settable(L, -3);
        }];
        return;
    }
    lua_pushnil(L);
}

static int l_jsonEncode(lua_State *L) {
    id obj = maLuaToObj(L, 1);
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!d) { lua_pushnil(L); return 1; }
    lua_pushlstring(L, (const char *)d.bytes, (size_t)d.length);
    return 1;
}
static int l_jsonDecode(lua_State *L) {
    size_t len = 0;
    const char *s = luaL_checklstring(L, 1, &len);
    id obj = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:s length:len] options:0 error:nil];
    if (!obj) { lua_pushnil(L); return 1; }
    maObjToLua(L, obj);
    return 1;
}

// ---------------- 剪贴板 / 应用 ----------------
// ---------------- 设备信息（复用 DeviceInfo 采集，JSON 缓存） ----------------
#import "DeviceInfo.h"

static NSDictionary *maDevInfo(void) {
    static NSDictionary *cache = nil;
    static NSTimeInterval cacheAt = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (cache && now - cacheAt < 2.0) return cache;
    NSData *d = MatisuDeviceInfoJSON();
    cache = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : @{};
    cacheAt = now;
    return cache;
}

static void pushInfoStr(lua_State *L, NSString *key) {
    id v = maDevInfo()[key];
    lua_pushstring(L, v ? [[v description] UTF8String] : "");
}
static void pushInfoInt(lua_State *L, NSString *key) {
    id v = maDevInfo()[key];
    lua_pushinteger(L, v ? (lua_Integer)[v longLongValue] : 0);
}

static int l_getModel(lua_State *L) { pushInfoStr(L, @"model"); return 1; }
static int l_getDeviceName(lua_State *L) { pushInfoStr(L, @"modelName"); return 1; }
static int l_getSysVer(lua_State *L) { pushInfoStr(L, @"systemVersion"); return 1; }
static int l_getDeviceId(lua_State *L) { pushInfoStr(L, @"model"); return 1; }   // machineId 即设备唯一标识
static int l_getBatteryLevel(lua_State *L) { pushInfoInt(L, @"battery"); return 1; }
static int l_isCharging(lua_State *L) { id v = maDevInfo()[@"charging"]; lua_pushboolean(L, v && [v boolValue]); return 1; }
static int l_frontAppName(lua_State *L) {
    NSString *fa = MatisuFrontApp() ?: @"";
    lua_pushstring(L, fa.UTF8String);
    return 1;
}
static int l_getScreenDirection(lua_State *L) {
    // 0=竖屏 1=横屏（与原版一致：竖 0/横 1）
    __block UIInterfaceOrientation o = UIInterfaceOrientationPortrait;
    void (^rd)(void) = ^{ o = [UIApplication sharedApplication].statusBarOrientation; };
    if ([NSThread isMainThread]) rd();
    else dispatch_sync(dispatch_get_main_queue(), rd);
    lua_pushinteger(L, UIInterfaceOrientationIsLandscape(o) ? 1 : 0);
    return 1;
}
static int l_getSysLang(lua_State *L) {
    NSString *lang = [[NSLocale preferredLanguages] firstObject] ?: @"";
    lua_pushstring(L, lang.UTF8String);
    return 1;
}
static int l_getSysTimezone(lua_State *L) {
    NSString *tz = [[NSTimeZone localTimeZone] name] ?: @"";
    lua_pushstring(L, tz.UTF8String);
    return 1;
}
static int l_getDeviceType(lua_State *L) {
    // 原版：0=手机 1=平板（iOS 端语义）
    lua_pushinteger(L, [UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad ? 1 : 0);
    return 1;
}
static int l_getEngineVersion(lua_State *L) {
    lua_pushstring(L, "MatisuAuto 0.1 (Lua 5.4)");
    return 1;
}
static int l_getScreenFrame(lua_State *L) {
    float w = 0, h = 0;
    maScreenSize(&w, &h);
    char buf[32];
    snprintf(buf, sizeof(buf), "%.0f,%.0f,%.0f,%.0f", 0.0f, 0.0f, w, h);
    lua_pushstring(L, buf);
    return 1;
}
static int l_getScreenResolution(lua_State *L) {
    id w = maDevInfo()[@"pixelWidth"], h = maDevInfo()[@"pixelHeight"];
    char buf[32];
    snprintf(buf, sizeof(buf), "%ldx%ld", (long)[w longValue], (long)[h longValue]);
    lua_pushstring(L, buf);
    return 1;
}

// ---------------- 日志控制台（设备端 log.txt） ----------------
static NSString *maLogPath(void) { return @"/var/mobile/MatisuAuto/log.txt"; }
static void maLogAppend(NSString *level, NSString *msg) {
    @autoreleasepool {
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"MM-dd HH:mm:ss";
        NSString *line = [NSString stringWithFormat:@"[%@][%@] %@\n", [fmt stringFromDate:[NSDate date]], level, msg];
        NSString *p = maLogPath();
        [[NSFileManager defaultManager] createDirectoryAtPath:[p stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        if (![[NSFileManager defaultManager] fileExistsAtPath:p]) {
            [line writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}
static int l_logLevel(lua_State *L, NSString *level) {
    int n = lua_gettop(L);
    NSMutableString *msg = [NSMutableString string];
    for (int i = 1; i <= n; i++) {
        size_t len = 0; const char *s = luaL_tolstring(L, i, &len);
        if (i > 1) [msg appendString:@"\t"];
        if (s) [msg appendString:[NSString stringWithUTF8String:s] ?: @"?"];
        lua_pop(L, 1);
    }
    maLogAppend(level, msg);
    return 0;
}
static int l_logPrint(lua_State *L) { return l_logLevel(L, @"INFO"); }
static int l_logDebug(lua_State *L) { return l_logLevel(L, @"DEBUG"); }
static int l_logInfo(lua_State *L) { return l_logLevel(L, @"INFO"); }
static int l_logWarn(lua_State *L) { return l_logLevel(L, @"WARN"); }
static int l_logError(lua_State *L) { return l_logLevel(L, @"ERROR"); }
static int l_vvLog(lua_State *L) { return l_logLevel(L, @"TRACE"); }
static int l_clearCLog(lua_State *L) {
    [@"" writeToFile:maLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return 0;
}

// ---------------- 脚本控制 ----------------
static int l_exitScript(lua_State *L) {
    return luaL_error(L, "__MATISU_EXIT__");
}
// setStopCallBack(fn)：常驻脚本被 stop 时回调（registry 存 ref）
#define MA_STOPCB_KEY "matisu_stopcb"
static int l_setStopCallBack(lua_State *L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    lua_pushvalue(L, 1);
    lua_setfield(L, LUA_REGISTRYINDEX, MA_STOPCB_KEY);
    return 0;
}
static void maInvokeStopCb(lua_State *L) {
    lua_getfield(L, LUA_REGISTRYINDEX, MA_STOPCB_KEY);
    if (lua_isfunction(L, -1)) lua_pcall(L, 0, 0, 0);
    else lua_pop(L, 1);
}

// ---------------- 批次 2：图色变体 / 别名表 / 杂项 ----------------
static int l_findMultiColorAll(lua_State *L) {
    // 原版签名 8 参：(x1,y1,x2,y2,first_color,offset_color,dir,sim)。
    // dir 对 All 变体只影响返回点序（集合相同），收下第 7 参但忽略，sim 取第 8 参。
    (void)luaL_optinteger(L, 7, 0);
    NSString *r = MatisuFindMultiColorAll((int)luaL_optinteger(L, 1, 0), (int)luaL_optinteger(L, 2, 0),
                                          (int)luaL_optinteger(L, 3, 0), (int)luaL_optinteger(L, 4, 0),
                                          [NSString stringWithUTF8String:luaL_checkstring(L, 5)],
                                          [NSString stringWithUTF8String:luaL_optstring(L, 6, "")],
                                          luaL_optnumber(L, 8, 0.9));
    lua_pushstring(L, r.UTF8String);
    return 1;
}
static int l_getScreenPixel(lua_State *L) {
    NSArray *arr = MatisuGetScreenPixel((int)luaL_optinteger(L, 1, 0), (int)luaL_optinteger(L, 2, 0),
                                        (int)luaL_optinteger(L, 3, 0), (int)luaL_optinteger(L, 4, 0));
    lua_createtable(L, (int)arr.count, 0);
    [arr enumerateObjectsUsingBlock:^(NSNumber *v, NSUInteger i, BOOL *stop) {
        lua_pushinteger(L, [v longLongValue]);
        lua_seti(L, -2, (lua_Integer)i + 1);
    }];
    return 1;
}
static int l_isDisplayDead(lua_State *L) {
    int r = MatisuIsDisplayDead((int)luaL_optinteger(L, 1, 0), (int)luaL_optinteger(L, 2, 0),
                                (int)luaL_optinteger(L, 3, 0), (int)luaL_optinteger(L, 4, 0),
                                luaL_optnumber(L, 5, 5));
    lua_pushinteger(L, r);
    return 1;
}
static int l_noopTrue(lua_State *L) { lua_pushboolean(L, 1); return 1; }   // keepCapture/releaseCapture/setScreenScale（设备端天然满足）
static int l_getCpuArch(lua_State *L) { lua_pushstring(L, "arm64"); return 1; }
static int l_getDisplayDpi(lua_State *L) {
    __block CGFloat sc = 2.0;
    void (^rd)(void) = ^{ sc = [UIScreen mainScreen].scale; };
    if ([NSThread isMainThread]) rd();
    else dispatch_sync(dispatch_get_main_queue(), rd);
    lua_pushinteger(L, (lua_Integer)lround(sc * 160));
    return 1;
}
static int l_getOsVersionName(lua_State *L) { pushInfoStr(L, @"systemVersion"); return 1; }
static int l_rnd(lua_State *L) {
    lua_Integer a = luaL_checkinteger(L, 1), b = luaL_checkinteger(L, 2);
    if (a > b) { lua_Integer t = a; a = b; b = t; }
    lua_pushinteger(L, a + (lua_Integer)arc4random_uniform((uint32_t)(b - a + 1)));
    return 1;
}
#import <AudioToolbox/AudioToolbox.h>
static int l_vibrate(lua_State *L) {
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
    lua_pushboolean(L, 1);
    return 1;
}
// restartScript：常驻脚本自我重启（stop 后由调用方/守护逻辑拉起；one-shot 下置标志由 runfile 层处理——简化为仅 service 语义）
static int l_restartScript(lua_State *L) {
    return luaL_error(L, "__MATISU_RESTART__");
}

// ---------------- OCR（PP-OCRv6 small 内置） ----------------
// ocrText(x1,y1,x2,y2) -> 纯文本（换行分隔）；区域 0,0,0,0=全屏
static int l_ocrText(lua_State *L) {
    NSArray<MAOcrItem*> *items = MatisuOcrRegion((int)luaL_optinteger(L, 1, 0), (int)luaL_optinteger(L, 2, 0),
                                                 (int)luaL_optinteger(L, 3, 0), (int)luaL_optinteger(L, 4, 0));
    NSMutableArray *texts = [NSMutableArray arrayWithCapacity:items.count];
    for (MAOcrItem *it in items) [texts addObject:it.text];
    lua_pushstring(L, [texts componentsJoinedByString:@"\n"].UTF8String);
    return 1;
}
// ocrTextEx(x1,y1,x2,y2) -> {{text=,x=,y=,w=,h=,score=}, ...}
static int l_ocrTextEx(lua_State *L) {
    NSArray<MAOcrItem*> *items = MatisuOcrRegion((int)luaL_optinteger(L, 1, 0), (int)luaL_optinteger(L, 2, 0),
                                                 (int)luaL_optinteger(L, 3, 0), (int)luaL_optinteger(L, 4, 0));
    lua_createtable(L, (int)items.count, 0);
    [items enumerateObjectsUsingBlock:^(MAOcrItem *it, NSUInteger i, BOOL *stop) {
        lua_createtable(L, 0, 6);
        lua_pushstring(L, it.text.UTF8String); lua_setfield(L, -2, "text");
        lua_pushinteger(L, it.x); lua_setfield(L, -2, "x");
        lua_pushinteger(L, it.y); lua_setfield(L, -2, "y");
        lua_pushinteger(L, it.w); lua_setfield(L, -2, "w");
        lua_pushinteger(L, it.h); lua_setfield(L, -2, "h");
        lua_pushnumber(L, it.score); lua_setfield(L, -2, "score");
        lua_seti(L, -2, (lua_Integer)i + 1);
    }];
    return 1;
}
// findStr(x1,y1,x2,y2, text) -> x,y（命中首行中心）；未命中 -1,-1
static int l_findStr(lua_State *L) {
    NSString *needle = [NSString stringWithUTF8String:luaL_checkstring(L, 5)];
    NSArray<MAOcrItem*> *items = MatisuOcrRegion((int)luaL_optinteger(L, 1, 0), (int)luaL_optinteger(L, 2, 0),
                                                 (int)luaL_optinteger(L, 3, 0), (int)luaL_optinteger(L, 4, 0));
    for (MAOcrItem *it in items) {
        if ([it.text containsString:needle]) {
            lua_pushinteger(L, it.x + it.w / 2);
            lua_pushinteger(L, it.y + it.h / 2);
            return 2;
        }
    }
    lua_pushinteger(L, -1);
    lua_pushinteger(L, -1);
    return 2;
}

static int l_readPasteboard(lua_State *L) {
    NSString *s = MatisuReadPasteboard();
    lua_pushstring(L, s.UTF8String);
    return 1;
}
static int l_writePasteboard(lua_State *L) {
    MatisuWritePasteboard([NSString stringWithUTF8String:luaL_checkstring(L, 1)]);
    lua_pushboolean(L, 1);
    return 1;
}
static int l_runApp(lua_State *L) {
    BOOL ok = MatisuOpenApp([NSString stringWithUTF8String:luaL_checkstring(L, 1)]);
    lua_pushboolean(L, ok);
    return 1;
}
/// stopApp(bundleId) -> true/false：按可执行名查进程后 SIGKILL（需 root）
static int l_stopApp(lua_State *L) {
    BOOL ok = MatisuStopApp([NSString stringWithUTF8String:luaL_checkstring(L, 1)]);
    lua_pushboolean(L, ok);
    return 1;
}
/// appIsRunning(bundleId) -> true/false
static int l_appIsRunning(lua_State *L) {
    BOOL ok = MatisuAppIsRunning([NSString stringWithUTF8String:luaL_checkstring(L, 1)]);
    lua_pushboolean(L, ok);
    return 1;
}
/// lockScreen() -> true/false
static int l_lockScreen(lua_State *L) {
    lua_pushboolean(L, MatisuLockScreen());
    return 1;
}
/// unLockScreen([password]) -> true/false
/// 无密码设备：点亮后从底部上滑即可；有密码则继续注入密码并回车。
static int l_unLockScreen(lua_State *L) {
    const char *pwd = luaL_optstring(L, 1, NULL);
    BOOL lit = MatisuUndimScreen();
    usleep(350 * 1000);
    float w = 0, h = 0;
    maScreenSize(&w, &h);
    if (w > 0 && h > 0) {
        MatisuTouchSwipe(w * 0.5f, h - 10.0f, w * 0.5f, h * 0.15f, 0.35);
    }
    if (pwd && *pwd) {
        usleep(900 * 1000);
        MatisuTypeText(pwd);
        usleep(400 * 1000);
        MatisuKeyPressName("return");
    }
    lua_pushboolean(L, lit);
    return 1;
}
/// keyDown(name) / keyUp(name)：按下不抬起，用于组合键（name 同 keyPress）
static int l_keyDown(lua_State *L) {
    MatisuKeyDownName(luaL_checkstring(L, 1));
    return 0;
}
static int l_keyUp(lua_State *L) {
    MatisuKeyUpName(luaL_checkstring(L, 1));
    return 0;
}
static int l_openUrl(lua_State *L) {
    BOOL ok = MatisuOpenURL([NSString stringWithUTF8String:luaL_checkstring(L, 1)]);
    lua_pushboolean(L, ok);
    return 1;
}

NSDictionary* _Nullable MatisuLuaRun(NSString *source) {
    if (!source) return nil;
    NSMutableString *out = [NSMutableString string];
    lua_State *L = luaL_newstate();
    if (!L) return @{ @"ok": @NO, @"output": @"", @"error": @"luaL_newstate failed" };
    luaL_openlibs(L);

    // 输出收集挂 registry
    lua_pushlightuserdata(L, (__bridge void *)out);
    lua_setfield(L, LUA_REGISTRYINDEX, MA_OUT_KEY);

    registerFns(L, l_print);

    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    int status = luaL_loadbufferx(L, source.UTF8String, (size_t)[source lengthOfBytesUsingEncoding:NSUTF8StringEncoding], "=script", "t");
    if (status == LUA_OK) status = lua_pcall(L, 0, 0, 0);
    if (status == LUA_OK) {
        r[@"ok"] = @YES;
        r[@"output"] = out;
    } else {
        const char *err = lua_tostring(L, -1);
        NSString *msg = err ? [NSString stringWithUTF8String:err] : @"unknown error";
        if ([msg containsString:@"__MATISU_EXIT__"]) {
            // exitScript() 主动结束：视为正常结束（对齐原版语义）
            r[@"ok"] = @YES;
            r[@"output"] = out;
        } else {
            r[@"ok"] = @NO;
            r[@"output"] = out;
            r[@"error"] = msg;
        }
    }
    lua_close(L);
    return r;
}

// ============================================================
// 常驻脚本服务态（单实例）+ 脚本目录管理
// ============================================================
#import <pthread.h>

static lua_State *gSvcL = NULL;
static volatile BOOL gSvcStop = NO;
static volatile BOOL gSvcRunning = NO;
static pthread_t gSvcTid;
static NSMutableString *gSvcOut = nil;
static NSLock *gSvcOutLock = nil;

NSString* _Nonnull MatisuScriptDir(void) {
    NSString *dir = @"/var/mobile/MatisuAuto/scripts";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

// 常驻 state 的 print 走共享输出（加锁）
static int l_printSvc(lua_State *L) {
    if (!gSvcOutLock) gSvcOutLock = [NSLock new];
    if (!gSvcOut) gSvcOut = [NSMutableString string];
    int n = lua_gettop(L);
    lua_getglobal(L, "tostring");
    [gSvcOutLock lock];
    for (int i = 1; i <= n; i++) {
        lua_pushvalue(L, -1);
        lua_pushvalue(L, i);
        lua_call(L, 1, 1);
        const char *s = lua_tostring(L, -1);
        if (i > 1) [gSvcOut appendString:@"\t"];
        if (s) [gSvcOut appendString:[NSString stringWithUTF8String:s] ?: @"?"];
        lua_pop(L, 1);
    }
    [gSvcOut appendString:@"\n"];
    [gSvcOutLock unlock];
    return 0;
}

// 中断 hook：stop 置位后抛错终止脚本
static void svcHook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    if (gSvcStop) luaL_error(L, "__MATISU_STOP__");
}

static void *svcThread(void *arg) {
    NSString *source = (__bridge_transfer NSString *)arg;
    NSString *srcCopy = [source copy];   // restartScript 自举用
    lua_State *L = luaL_newstate();
    if (L) {
        luaL_openlibs(L);
        registerFns(L, l_printSvc);
        lua_sethook(L, svcHook, LUA_MASKCOUNT, 50);
        int status = luaL_loadbufferx(L, source.UTF8String,
                                      (size_t)[source lengthOfBytesUsingEncoding:NSUTF8StringEncoding], "=service", "t");
        if (status == LUA_OK) status = lua_pcall(L, 0, 0, 0);
        BOOL restart = NO;
        if (status != LUA_OK) {
            const char *err = lua_tostring(L, -1);
            NSString *msg = err ? [NSString stringWithUTF8String:err] : @"unknown";
            if ([msg containsString:@"__MATISU_STOP__"]) {
                maInvokeStopCb(L);   // 用户 stop → setStopCallBack 回调
            } else if ([msg containsString:@"__MATISU_RESTART__"]) {
                restart = YES;
            } else if (![msg containsString:@"__MATISU_EXIT__"]) {
                [gSvcOutLock lock];
                [gSvcOut appendFormat:@"[service error] %@\n", msg];
                [gSvcOutLock unlock];
            }
        }
        lua_close(L);
        gSvcL = NULL;
        gSvcRunning = NO;
        if (restart) MatisuLuaStart(srcCopy);   // restartScript：自举重跑同一源码
        return NULL;
    }
    gSvcL = NULL;
    gSvcRunning = NO;
    return NULL;
}

BOOL MatisuLuaStart(NSString *source) {
    if (gSvcRunning || !source) return NO;
    if (!gSvcOutLock) gSvcOutLock = [NSLock new];
    if (!gSvcOut) gSvcOut = [NSMutableString string];
    gSvcStop = NO;
    gSvcRunning = YES;
    pthread_create(&gSvcTid, NULL, svcThread, (__bridge_retained void *)source);
    pthread_detach(gSvcTid);
    return YES;
}

void MatisuLuaStop(void) {
    if (!gSvcRunning) return;
    gSvcStop = YES;   // hook 下一拍触发 luaL_error
}

BOOL MatisuLuaRunning(void) { return gSvcRunning; }

NSString* _Nonnull MatisuLuaDrainOutput(void) {
    if (!gSvcOutLock) gSvcOutLock = [NSLock new];
    if (!gSvcOut) gSvcOut = [NSMutableString string];
    [gSvcOutLock lock];
    NSString *r = [gSvcOut copy];
    [gSvcOut setString:@""];
    [gSvcOutLock unlock];
    return r;
}

// 工程打包形态：app bundle 内 scripts/（安装后 /var/jb/Applications/MatisuAuto.app/scripts/）
// 首启同步到 /var/mobile/MatisuAuto/scripts/（mobile 可写），以 bundle 内版本为准覆盖同名文件。
static void syncBundledScripts(void) {
    NSString *bundleDir = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"scripts"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:bundleDir]) return;
    NSString *dest = MatisuScriptDir();
    NSArray *items = [fm contentsOfDirectoryAtPath:bundleDir error:nil];
    for (NSString *name in items) {
        NSString *src = [bundleDir stringByAppendingPathComponent:name];
        NSString *dst = [dest stringByAppendingPathComponent:name];
        // 以 bundle 内为准：内容不同才覆盖
        NSData *a = [NSData dataWithContentsOfFile:src];
        NSData *b = [NSData dataWithContentsOfFile:dst];
        if (a && ![a isEqualToData:b]) {
            [fm removeItemAtPath:dst error:nil];
            [fm copyItemAtPath:src toPath:dst error:nil];
            NSLog(@"[MatisuAuto] bundled script synced: %@", name);
        }
    }
}

void MatisuLuaAutoRun(void) {
    syncBundledScripts();
    NSString *f = [MatisuScriptDir() stringByAppendingPathComponent:@"autorun.lua"];
    NSString *src = [NSString stringWithContentsOfFile:f encoding:NSUTF8StringEncoding error:nil];
    if (src.length) {
        BOOL ok = MatisuLuaStart(src);
        NSLog(@"[MatisuAuto] autorun.lua %@", ok ? @"started" : @"start failed");
    }
}

// FNS 表共享注册（one-shot 用 l_print，常驻用 l_printSvc）
static void registerFns(lua_State *L, lua_CFunction printFn) {
    static const struct { const char *name; lua_CFunction fn; } FNS[] = {
        { "tap", l_tap }, { "longTap", l_longTap }, { "swipe", l_swipe },
        { "touchDown", l_touchDown }, { "touchMove", l_touchMove }, { "touchUp", l_touchUp },
        { "keyPress", l_keyPress }, { "inputText", l_inputText },
        { "getDisplaySize", l_getDisplaySize },
        { "getPixelColor", l_getPixelColor },
        { "sleep", l_sleep }, { "mSleep", l_mSleep },
        { "findColor", l_findColor }, { "cmpColor", l_cmpColor },
        { "cmpColorEx", l_cmpColorEx }, { "getColorNum", l_getColorNum },
        { "snapShot", l_snapShot },
        { "findPic", l_findPic }, { "findPicEx", l_findPicEx },
        { "findPicAllPoint", l_findPicAllPoint }, { "findCircle", l_findCircle },
        { "findMultiColor", l_findMultiColor },
        { "httpGet", l_httpGet }, { "httpPost", l_httpPost },
        { "MD5", l_MD5 }, { "encodeBase64", l_encodeBase64 }, { "decodeBase64", l_decodeBase64 },
        { "readPasteboard", l_readPasteboard }, { "writePasteboard", l_writePasteboard },
        { "runApp", l_runApp }, { "openUrl", l_openUrl },
        { "stopApp", l_stopApp }, { "appIsRunning", l_appIsRunning },
        { "lockScreen", l_lockScreen }, { "unLockScreen", l_unLockScreen },
        // 批次 3：按键按下/抬起（组合键）
        { "keyDown", l_keyDown }, { "keyUp", l_keyUp },
        // 批次 3：*T table 传参变体 + 颜色工具
        { "findColorT", l_findColorT }, { "findMultiColorT", l_findMultiColorT },
        { "findMultiColorAllT", l_findMultiColorAllT }, { "cmpColorExT", l_cmpColorExT },
        { "colorDiff", l_colorDiff }, { "colorToRGB", l_colorToRGB },
        { "downloadFile", l_download },
        // 设备信息
        { "getModel", l_getModel }, { "getDeviceName", l_getDeviceName },
        { "getSysVer", l_getSysVer }, { "getDeviceId", l_getDeviceId },
        { "getBatteryLevel", l_getBatteryLevel }, { "isCharging", l_isCharging },
        { "frontAppName", l_frontAppName }, { "getScreenDirection", l_getScreenDirection },
        { "getSysLang", l_getSysLang }, { "getSysTimezone", l_getSysTimezone },
        { "getDeviceType", l_getDeviceType }, { "getEngineVersion", l_getEngineVersion },
        { "getScreenFrame", l_getScreenFrame }, { "getScreenResolution", l_getScreenResolution },
        // 日志控制台
        { "logPrint", l_logPrint }, { "logDebug", l_logDebug }, { "logInfo", l_logInfo },
        { "logWarn", l_logWarn }, { "logError", l_logError }, { "vvLog", l_vvLog },
        { "clearCLog", l_clearCLog },
        // 脚本控制
        { "exitScript", l_exitScript }, { "setStopCallBack", l_setStopCallBack },
        { "restartScript", l_restartScript },
        // 批次 2：图色变体 / 截图缓存 / 杂项
        { "findMultiColorAll", l_findMultiColorAll },
        { "getScreenPixel", l_getScreenPixel }, { "isDisplayDead", l_isDisplayDead },
        { "keepCapture", l_noopTrue }, { "releaseCapture", l_noopTrue }, { "setScreenScale", l_noopTrue },
        { "getCpuArch", l_getCpuArch }, { "getDisplayDpi", l_getDisplayDpi },
        { "getOsVersionName", l_getOsVersionName },
        { "rnd", l_rnd }, { "vibrate", l_vibrate },
        // findPic 家族别名（findPicFast/findImage 设备端实现同 findPic，本就近零成本）
        { "findPicFast", l_findPic }, { "findImage", l_findPic },
        // OCR（PP-OCRv6 small 内置）
        { "ocrText", l_ocrText }, { "ocrTextEx", l_ocrTextEx }, { "findStr", l_findStr },
        { NULL, NULL },
    };
    // jsonLib 表（encode/decode）
    lua_createtable(L, 0, 2);
    lua_pushcfunction(L, l_jsonEncode); lua_setfield(L, -2, "encode");
    lua_pushcfunction(L, l_jsonDecode); lua_setfield(L, -2, "decode");
    lua_setglobal(L, "jsonLib");
    // 别名表：json / network / cipher（对齐原版别名习惯）
    lua_createtable(L, 0, 2);
    lua_pushcfunction(L, l_jsonEncode); lua_setfield(L, -2, "encode");
    lua_pushcfunction(L, l_jsonDecode); lua_setfield(L, -2, "decode");
    lua_setglobal(L, "json");
    lua_createtable(L, 0, 3);
    lua_pushcfunction(L, l_httpGet); lua_setfield(L, -2, "httpGet");
    lua_pushcfunction(L, l_httpPost); lua_setfield(L, -2, "httpPost");
    lua_pushcfunction(L, l_download); lua_setfield(L, -2, "download");
    lua_setglobal(L, "network");
    lua_createtable(L, 0, 3);
    lua_pushcfunction(L, l_MD5); lua_setfield(L, -2, "md5");
    lua_pushcfunction(L, l_sha1); lua_setfield(L, -2, "sha1");
    lua_pushcfunction(L, l_encodeBase64); lua_setfield(L, -2, "base64");
    lua_setglobal(L, "cipher");
    lua_pushcfunction(L, printFn);
    lua_setglobal(L, "print");
    for (int i = 0; FNS[i].name; i++) {
        lua_pushcfunction(L, FNS[i].fn);
        lua_setglobal(L, FNS[i].name);
    }
}
