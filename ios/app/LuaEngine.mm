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
#import "MatisuPaths.h"
#import "ShowUI.h"
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
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

// 前向声明：print 镜像落盘（定义在日志控制台段）
static void maEngineLogAppend(NSString *text);
static NSString *maPrintMirror(lua_State *L, NSString *line);

static int l_print(lua_State *L) {
    NSMutableString *out = maOut(L);
    int n = lua_gettop(L);
    lua_getglobal(L, "tostring");
    NSMutableString *line = [NSMutableString string];
    for (int i = 1; i <= n; i++) {
        lua_pushvalue(L, -1);
        lua_pushvalue(L, i);
        lua_call(L, 1, 1);
        const char *s = lua_tostring(L, -1);
        if (i > 1) [line appendString:@"\t"];
        if (s) [line appendString:[NSString stringWithUTF8String:s] ?: @"?"];
        lua_pop(L, 1);
    }
    [line appendString:@"\n"];
    [out appendString:line];
    // 引擎日志镜像（IDE 日志流）：带 [文件:行号] 定位前缀；output 缓冲保持原文
    maEngineLogAppend(maPrintMirror(L, line));
    return 0;
}

// print 镜像行加定位前缀：luaL_where(1) 取调用方 chunk:line（"main.lua:42:"）
// output 缓冲（run 指令回传/读文件复用）不受影响，仅落盘镜像带前缀。
static NSString *maPrintMirror(lua_State *L, NSString *line) {
    luaL_where(L, 1);
    const char *w = lua_tostring(L, -1);
    NSString *where = w ? [NSString stringWithUTF8String:w] : @"";
    lua_pop(L, 1);
    if (!where.length) return line;
    // luaL_where 格式为 "chunk:line: "（冒号后带空格），剥掉尾部空白与冒号
    where = [where stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([where hasSuffix:@":"]) where = [where substringToIndex:where.length - 1];
    return [NSString stringWithFormat:@"[%@] %@", where, line];
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

// ---- 脚本停止通道：gSvcStop=常驻 / gRunStop=one-shot(F5)，stop 命令置位 ----
static volatile BOOL gSvcStop = NO;
static volatile BOOL gRunStop = NO;
static BOOL maStopRequested(void) { return gSvcStop || gRunStop; }
static void runHook(lua_State *L, lua_Debug *ar);   // 定义在下方引擎服务态段

static int l_sleep(lua_State *L) {
    lua_Integer ms = (lua_Integer)(luaL_checknumber(L, 1) * 1000);
    lua_Integer left = ms > 0 ? ms : 0;
    while (left > 0) {
        if (maStopRequested()) return luaL_error(L, "__MATISU_STOP__");
        lua_Integer step = left > 50 ? 50 : left;
        usleep((useconds_t)(step * 1000));
        left -= step;
    }
    return 0;
}
static int l_mSleep(lua_State *L) {
    lua_Integer left = luaL_checkinteger(L, 1);
    while (left > 0) {
        if (maStopRequested()) return luaL_error(L, "__MATISU_STOP__");
        lua_Integer step = left > 50 ? 50 : left;
        usleep((useconds_t)(step * 1000));
        left -= step;
    }
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
// 颜色参数：字符串按 16 进制解析（"BBGGRR"/"0x..."），数字直取（字符串经 lua 强转会变十进制，必须自己 strtoul）
static unsigned int maColorArg(lua_State *L, int idx) {
    if (lua_type(L, idx) == LUA_TSTRING)
        return (unsigned int)strtoul(lua_tostring(L, idx), NULL, 16);
    return (unsigned int)luaL_checkinteger(L, idx);
}
static int l_colorDiff(lua_State *L) {
    unsigned int c1 = maColorArg(L, 1);
    unsigned int c2 = maColorArg(L, 2);
    // BBGGRR：低字节是 R（对齐原版文档与 core.lua/Android）
    int r1 = c1 & 0xFF, g1 = (c1 >> 8) & 0xFF, b1 = (c1 >> 16) & 0xFF;
    int r2 = c2 & 0xFF, g2 = (c2 >> 8) & 0xFF, b2 = (c2 >> 16) & 0xFF;
    lua_pushinteger(L, abs(r1 - r2) + abs(g1 - g2) + abs(b1 - b2));
    return 1;
}
// colorToRGB(c) -> r,g,b（BBGGRR：低字节是 R）
static int l_colorToRGB(lua_State *L) {
    unsigned int c = maColorArg(L, 1);
    lua_pushinteger(L, c & 0xFF);
    lua_pushinteger(L, (c >> 8) & 0xFF);
    lua_pushinteger(L, (c >> 16) & 0xFF);
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

// ---------------- cryptLib（AES: CCCryptor 全模式；RSA: Security.framework，PEM PKCS#1/#8/SPKI 互认） ----------------
// AES-ECB 单块原语（公共 API），供流模式手工实现复用
static BOOL maAesEcbBlock(const unsigned char *key, size_t klen, const unsigned char *in, unsigned char *out) {
    size_t moved = 0;
    return CCCrypt(kCCEncrypt, kCCAlgorithmAES128, kCCOptionECBMode, key, klen, NULL,
                   in, 16, out, 16, &moved) == kCCSuccess;
}
// l_cryptAes：ecb/cbc 走 CCCrypt；cfb(=CFB8)/ofb(=OFB128)/ctr 用 ECB 单块原语手工实现，
// 与 Android 端 aesEcbBlock 同一套字节级逻辑（PKCS7 在流模式下手工填充，两端一致）。
static int l_cryptAes(lua_State *L) {
    size_t dlen = 0, klen = 0;
    const unsigned char *data = (const unsigned char *)luaL_checklstring(L, 1, &dlen);
    const unsigned char *key = (const unsigned char *)luaL_checklstring(L, 2, &klen);
    const char *op = luaL_checkstring(L, 3);
    const char *mode = luaL_checkstring(L, 4);
    const char *iv = luaL_optstring(L, 5, NULL);
    int padding = lua_isnoneornil(L, 6) ? 1 : lua_toboolean(L, 6);
    if (klen != 16 && klen != 24 && klen != 32) return luaL_error(L, "aes key length must be 16/24/32");
    BOOL enc = strcmp(op, "encrypt") == 0;
    int m;   // 0=ecb 1=cbc 2=cfb8 3=ofb128 4=ctr
    if      (!strcmp(mode, "ecb")) m = 0;
    else if (!strcmp(mode, "cbc")) m = 1;
    else if (!strcmp(mode, "cfb")) m = 2;
    else if (!strcmp(mode, "ofb")) m = 3;
    else if (!strcmp(mode, "ctr")) m = 4;
    else return luaL_error(L, "unsupported aes mode: %s", mode);
    if (m >= 2 && (!iv || strlen(iv) != 16))
        return luaL_error(L, "aes mode %s requires 16-byte iv", mode);

    if (m <= 1) {   // ECB/CBC：CCCrypt 直通
        CCOptions opts = (m == 0 ? kCCOptionECBMode : 0) | (padding ? kCCOptionPKCS7Padding : 0);
        size_t outsz = dlen + 32;
        NSMutableData *out = [NSMutableData dataWithLength:outsz];
        size_t moved = 0;
        CCCryptorStatus st = CCCrypt(enc ? kCCEncrypt : kCCDecrypt, kCCAlgorithmAES128, opts,
                                     key, klen, iv, data, dlen, out.mutableBytes, outsz, &moved);
        if (st != kCCSuccess) return luaL_error(L, "aes crypt failed %d", st);
        lua_pushlstring(L, (const char *)out.bytes, moved);
        return 1;
    }
    // 流模式：PKCS7 手工填充/去填
    const unsigned char *src = data;
    NSMutableData *tmp = nil;
    if (enc && padding) {
        int pad = 16 - (int)(dlen % 16);
        tmp = [NSMutableData dataWithLength:dlen + pad];
        memcpy(tmp.mutableBytes, data, dlen);
        memset((unsigned char *)tmp.mutableBytes + dlen, pad, pad);
        src = (const unsigned char *)tmp.bytes; dlen += pad;
    } else if (!enc && padding) {
        if (dlen == 0 || dlen % 16 != 0) return luaL_error(L, "aes decrypt: bad padded length");
    }
    unsigned char reg[16], ks[16];
    memcpy(reg, iv, 16);
    NSMutableData *out = [NSMutableData dataWithLength:dlen];
    unsigned char *o = (unsigned char *)out.mutableBytes;
    if (m == 4) {          // CTR：计数器大端自增，加解密同操作
        for (size_t off = 0; off < dlen; off += 16) {
            if (!maAesEcbBlock(key, klen, reg, ks)) return luaL_error(L, "aes crypt failed");
            size_t n = (dlen - off) < 16 ? (dlen - off) : 16;
            for (size_t i = 0; i < n; i++) o[off + i] = src[off + i] ^ ks[i];
            for (int i = 15; i >= 0; i--) { reg[i] = (unsigned char)(reg[i] + 1); if (reg[i]) break; }
        }
    } else if (m == 3) {   // OFB128：寄存器自反馈
        for (size_t off = 0; off < dlen; off += 16) {
            if (!maAesEcbBlock(key, klen, reg, reg)) return luaL_error(L, "aes crypt failed");
            size_t n = (dlen - off) < 16 ? (dlen - off) : 16;
            for (size_t i = 0; i < n; i++) o[off + i] = src[off + i] ^ reg[i];
        }
    } else {               // CFB8：逐字节；加密反馈输出密文，解密反馈收到的密文字节
        for (size_t i = 0; i < dlen; i++) {
            if (!maAesEcbBlock(key, klen, reg, ks)) return luaL_error(L, "aes crypt failed");
            unsigned char c = src[i] ^ ks[0];
            o[i] = c;
            memmove(reg, reg + 1, 15);
            reg[15] = enc ? c : src[i];
        }
    }
    if (!enc && padding && dlen > 0) {
        int pad = o[dlen - 1];
        if (pad < 1 || pad > 16 || (size_t)pad > dlen) return luaL_error(L, "aes decrypt: bad padding");
        dlen -= pad;
    }
    lua_pushlstring(L, (const char *)out.bytes, dlen);
    return 1;
}
static int l_cryptAesKeygen(lua_State *L) {
    int n = (int)luaL_checkinteger(L, 1);
    if (n != 16 && n != 24 && n != 32) return luaL_error(L, "key length must be 16/24/32");
    unsigned char buf[32];
    if (SecRandomCopyBytes(kSecRandomDefault, (size_t)n, buf) != errSecSuccess)
        return luaL_error(L, "random gen failed");
    lua_pushlstring(L, (const char *)buf, (size_t)n);
    return 1;
}
static int l_cryptAesIvgen(lua_State *L) {
    unsigned char buf[16];
    if (SecRandomCopyBytes(kSecRandomDefault, 16, buf) != errSecSuccess)
        return luaL_error(L, "random gen failed");
    lua_pushlstring(L, (const char *)buf, 16);
    return 1;
}

// --- DER 小工具：PKCS#1 <-> SPKI/PKCS#8 包装与解包 ---
static void maDerAppendLen(NSMutableData *d, size_t n) {
    if (n < 0x80) { unsigned char b = (unsigned char)n; [d appendBytes:&b length:1]; }
    else if (n <= 0xFF) { unsigned char b[2] = {0x81, (unsigned char)n}; [d appendBytes:b length:2]; }
    else { unsigned char b[3] = {0x82, (unsigned char)(n >> 8), (unsigned char)(n & 0xFF)}; [d appendBytes:b length:3]; }
}
static NSMutableData *maDerTlv(unsigned char tag, NSData *content) {
    NSMutableData *d = [NSMutableData data];
    [d appendBytes:&tag length:1];
    maDerAppendLen(d, content.length);
    [d appendData:content];
    return d;
}
static NSMutableData *maRsaAlgId(void) {
    NSMutableData *alg = [NSMutableData data];
    unsigned char oidTlv[11] = {0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01};
    [alg appendBytes:oidTlv length:11];
    unsigned char nullTlv[2] = {0x05, 0x00};
    [alg appendBytes:nullTlv length:2];
    return alg;
}
static NSData *maPkcs1PubToSpki(NSData *pkcs1) {
    NSMutableData *bit = [NSMutableData data];
    unsigned char zero = 0;
    [bit appendBytes:&zero length:1];
    [bit appendData:pkcs1];
    NSMutableData *inner = [NSMutableData data];
    [inner appendData:maDerTlv(0x30, maRsaAlgId())];
    [inner appendData:maDerTlv(0x03, bit)];
    return maDerTlv(0x30, inner);
}
static NSData *maPkcs1PrivToPkcs8(NSData *pkcs1) {
    unsigned char verTlv[3] = {0x02, 0x01, 0x00};
    NSMutableData *inner = [NSMutableData data];
    [inner appendBytes:verTlv length:3];
    [inner appendData:maDerTlv(0x30, maRsaAlgId())];
    [inner appendData:maDerTlv(0x04, pkcs1)];
    return maDerTlv(0x30, inner);
}
static BOOL maDerReadLen(const unsigned char *b, size_t n, size_t pos, size_t *outLen, size_t *outAdv) {
    if (pos >= n) return NO;
    unsigned char f = b[pos];
    if (f < 0x80) { *outLen = f; *outAdv = 1; return YES; }
    int cnt = f & 0x7F;
    if (cnt == 0 || cnt > 4 || pos + (size_t)cnt >= n) return NO;
    uint64_t v = 0;
    for (int i = 0; i < cnt; i++) v = (v << 8) | b[pos + 1 + i];
    *outLen = (size_t)v; *outAdv = (size_t)cnt + 1;
    return YES;
}
// 任意 RSA DER（PKCS#1 / SPKI / PKCS#8）→ PKCS#1 裸结构
// 注意：PKCS#8 与 PKCS#1 私钥首字段同为 INTEGER(version)，须看第二内层字段
// （SEQUENCE=算法标识 → PKCS#8；INTEGER=模数 → 已是 PKCS#1）区分。
static NSData *maDerToPkcs1(NSData *der) {
    const unsigned char *b = (const unsigned char *)der.bytes;
    size_t n = der.length;
    if (n < 2 || b[0] != 0x30) return der;
    size_t pos = 1, adv = 0; size_t outerLen = 0;
    if (!maDerReadLen(b, n, pos, &outerLen, &adv)) return der;
    pos += adv;
    if (pos >= n) return der;
    unsigned char t1 = b[pos];
    if (t1 == 0x02) {                                        // INTEGER(version)：PKCS#1 私钥 或 PKCS#8 私钥
        size_t len1 = 0;
        if (!maDerReadLen(b, n, pos + 1, &len1, &adv)) return der;
        size_t p2 = pos + 1 + adv + len1;
        if (p2 >= n) return der;
        if (b[p2] != 0x30) return der;                       // INTEGER(模数) → 已是 PKCS#1
        size_t lenA = 0;                                     // PKCS#8：跳过算法 SEQUENCE
        if (!maDerReadLen(b, n, p2 + 1, &lenA, &adv)) return der;
        p2 = p2 + 1 + adv + lenA;
        if (p2 >= n || b[p2] != 0x04) return der;
        size_t lenO = 0;
        if (!maDerReadLen(b, n, p2 + 1, &lenO, &adv)) return der;
        size_t cs = p2 + 1 + adv;
        if (cs + lenO > n) return der;
        return [NSData dataWithBytes:b + cs length:lenO];
    }
    if (t1 == 0x30) {                                        // SEQUENCE(算法标识) → SPKI 公钥
        size_t len1 = 0;
        if (!maDerReadLen(b, n, pos + 1, &len1, &adv)) return der;
        pos = pos + 1 + adv + len1;
        if (pos >= n || b[pos] != 0x03) return der;
        size_t len2 = 0;
        if (!maDerReadLen(b, n, pos + 1, &len2, &adv)) return der;
        size_t cs = pos + 1 + adv;
        cs++;                                                // BIT STRING 跳过未用位数 0x00
        if (cs >= n) return der;
        return [NSData dataWithBytes:b + cs length:n - cs];
    }
    return der;
}
static NSString *maPemWrap(NSString *label, NSData *der) {
    NSString *b64 = [der base64EncodedStringWithOptions:0];
    NSMutableString *out = [NSMutableString stringWithFormat:@"-----BEGIN %@-----\n", label];
    for (NSUInteger i = 0; i < b64.length; i += 64) {
        NSUInteger e = MIN(i + 64, b64.length);
        [out appendFormat:@"%@\n", [b64 substringWithRange:NSMakeRange(i, e - i)]];
    }
    [out appendFormat:@"-----END %@-----", label];
    return out;
}
static NSData *maPemUnwrap(NSString *pem) {
    // 过滤掉 PEM 标记行与所有空白，只保留 base64 字符
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < pem.length; i++) {
        unichar c = [pem characterAtIndex:i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
            c == '+' || c == '/' || c == '=')
            [s appendFormat:@"%C", c];
    }
    maRsaDbg([NSString stringWithFormat:@"pemUnwrap: s=%lu head=%@", (unsigned long)s.length, [s substringToIndex:MIN(20, s.length)]]);
    NSData *d = [[NSData alloc] initWithBase64EncodedString:s options:NSDataBase64DecodingIgnoreUnknownCharacters];
    maRsaDbg([NSString stringWithFormat:@"pemUnwrap: decoded=%lu", (unsigned long)d.length]);
    return d;
}
static NSDictionary *maRsaKeyAttrs(BOOL isPublic, int bits) {
    // 不带 kSecAttrKeySizeInBits：导入时按数据实际大小接受（生成时才需显式位数）
    return @{(id)kSecAttrKeyType: (id)kSecAttrKeyTypeRSA,
             (id)kSecAttrKeyClass: (id)(isPublic ? kSecAttrKeyClassPublic : kSecAttrKeyClassPrivate)};
}
static int l_cryptRsaKeygen(lua_State *L) {
    int bits = (int)luaL_optinteger(L, 1, 2048);
    if (bits < 1024 || bits > 4096) return luaL_error(L, "rsa bits must be 1024/2048/4096");
    NSDictionary *attrs = @{(id)kSecAttrKeyType: (id)kSecAttrKeyTypeRSA,
                            (id)kSecAttrKeySizeInBits: @(bits)};
    CFErrorRef err = NULL;
    SecKeyRef priv = SecKeyCreateRandomKey((__bridge CFDictionaryRef)attrs, &err);
    if (!priv) return luaL_error(L, "rsa keygen failed");
    NSData *pkcs1Priv = CFBridgingRelease(SecKeyCopyExternalRepresentation(priv, &err));
    SecKeyRef pub = SecKeyCopyPublicKey(priv);
    NSData *pkcs1Pub = CFBridgingRelease(SecKeyCopyExternalRepresentation(pub, &err));
    NSString *pubPem = maPemWrap(@"PUBLIC KEY", maPkcs1PubToSpki(pkcs1Pub));
    NSString *privPem = maPemWrap(@"PRIVATE KEY", maPkcs1PrivToPkcs8(pkcs1Priv));
    CFRelease(priv); CFRelease(pub);
    lua_pushstring(L, pubPem.UTF8String);
    lua_pushstring(L, privPem.UTF8String);
    return 2;
}
static void maRsaDbg(NSString *line) {   // 临时诊断：写 logdir/rsa_debug.log
    @autoreleasepool {
        NSString *dir = MatisuLogDir();
        NSString *p = [dir stringByAppendingPathComponent:@"rsa_debug.log"];
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"HH:mm:ss.SSS";
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        NSData *d = [[NSString stringWithFormat:@"%@ %@\n", [f stringFromDate:[NSDate date]], line] dataUsingEncoding:NSUTF8StringEncoding];
        if (!fh) { [[NSFileManager defaultManager] createFileAtPath:p contents:nil attributes:nil]; fh = [NSFileHandle fileHandleForWritingAtPath:p]; }
        if (fh) { [fh seekToEndOfFile]; [fh writeData:d]; [fh closeFile]; }
    }
}
static SecKeyRef maRsaImport(NSString *pem, BOOL isPublic) {
    NSData *raw = maPemUnwrap(pem);
    NSData *pkcs1 = maDerToPkcs1(raw);
    const unsigned char *hb = (const unsigned char *)pkcs1.bytes;
    maRsaDbg([NSString stringWithFormat:@"import: pem=%lu raw=%lu pkcs1=%lu pub=%d head=%02x%02x%02x%02x",
              (unsigned long)pem.length, (unsigned long)raw.length, (unsigned long)pkcs1.length, isPublic ? 1 : 0,
              pkcs1.length > 3 ? hb[0] : 0, pkcs1.length > 3 ? hb[1] : 0,
              pkcs1.length > 3 ? hb[2] : 0, pkcs1.length > 3 ? hb[3] : 0]);
    if (!pkcs1.length) return NULL;
    CFErrorRef err = NULL;
    SecKeyRef k = SecKeyCreateWithData((__bridge CFDataRef)pkcs1, (__bridge CFDictionaryRef)maRsaKeyAttrs(isPublic, 2048), &err);
    if (!k) {
        NSString *desc = err ? (__bridge_transfer NSString *)CFErrorCopyDescription(err) : @"nil";
        maRsaDbg([NSString stringWithFormat:@"import FAILED: %@", desc]);
    }
    return k;   // 调用方负责 CFRelease
}
static int l_cryptRsaEncrypt(lua_State *L) {
    size_t dlen = 0;
    const char *data = luaL_checklstring(L, 1, &dlen);
    NSString *pem = [NSString stringWithUTF8String:luaL_checkstring(L, 2)];
    BOOL isPublic = lua_toboolean(L, 3);
    SecKeyRef key = maRsaImport(pem, isPublic);
    if (!key) return luaL_error(L, "rsa import key failed");
    CFErrorRef err = NULL;
    NSData *out = CFBridgingRelease(SecKeyCreateEncryptedData(key, kSecKeyAlgorithmRSAEncryptionPKCS1,
                                                              (__bridge CFDataRef)[NSData dataWithBytes:data length:dlen], &err));
    CFRelease(key);
    if (!out) return luaL_error(L, "rsa encrypt failed");
    lua_pushlstring(L, (const char *)out.bytes, (size_t)out.length);
    return 1;
}
static int l_cryptRsaDecrypt(lua_State *L) {
    size_t dlen = 0;
    const char *data = luaL_checklstring(L, 1, &dlen);
    NSString *pem = [NSString stringWithUTF8String:luaL_checkstring(L, 2)];
    BOOL isPublic = lua_toboolean(L, 3);
    SecKeyRef key = maRsaImport(pem, isPublic);
    if (!key) return luaL_error(L, "rsa import key failed");
    CFErrorRef err = NULL;
    NSData *out = CFBridgingRelease(SecKeyCreateDecryptedData(key, kSecKeyAlgorithmRSAEncryptionPKCS1,
                                                              (__bridge CFDataRef)[NSData dataWithBytes:data length:dlen], &err));
    CFRelease(key);
    if (!out) return luaL_error(L, "rsa decrypt failed");
    lua_pushlstring(L, (const char *)out.bytes, (size_t)out.length);
    return 1;
}

// ---------------- QDictionary（键值字典，JSON 文件持久化到工作目录） ----------------
static NSString *qdPath(NSString *name) {
    NSMutableString *safe = [name mutableCopy];
    [safe replaceOccurrencesOfString:@"/" withString:@"_" options:0 range:NSMakeRange(0, safe.length)];
    return [MatisuWorkDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"qdict_%@.json", safe]];
}
static NSMutableDictionary *qdLoad(NSString *name) {
    NSData *d = [NSData dataWithContentsOfFile:qdPath(name)];
    if (!d) return [NSMutableDictionary dictionary];
    id obj = [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil];
    if ([obj isKindOfClass:[NSMutableDictionary class]]) return obj;
    return [NSMutableDictionary dictionary];
}
static BOOL qdSave(NSString *name, NSDictionary *dict) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (!d) return NO;
    return [d writeToFile:qdPath(name) atomically:YES];
}
static NSString *qdSelfName(lua_State *L) {
    lua_getfield(L, 1, "_name");
    NSString *name = [NSString stringWithUTF8String:lua_tostring(L, -1) ?: ""];
    lua_pop(L, 1);
    return name;
}
static id qdLuaToStore(lua_State *L, int idx) {   // put 的值：nil->空串 / number(int/double) / bool / string
    switch (lua_type(L, idx)) {
        case LUA_TNIL:     return @"";
        case LUA_TBOOLEAN: return @(lua_toboolean(L, idx) ? YES : NO);
        case LUA_TNUMBER: {
            double v = lua_tonumber(L, idx);
            if (v == floor(v) && v >= -9007199254740992.0 && v <= 9007199254740992.0)
                return [NSNumber numberWithLongLong:(long long)v];
            return @(v);
        }
        default: return [NSString stringWithUTF8String:lua_tostring(L, idx) ?: ""];
    }
}
static void qdPushStore(lua_State *L, id v) {     // get：按存储类型还原 Lua 值
    if (!v || v == [NSNull null]) { lua_pushnil(L); return; }
    if ([v isKindOfClass:[NSString class]]) { lua_pushstring(L, [v UTF8String]); return; }
    if ([v isKindOfClass:[NSNumber class]]) {
        NSNumber *n = v;
        if (strcmp([n objCType], "c") == 0 || strcmp([n objCType], "B") == 0) { lua_pushboolean(L, n.boolValue); return; }
        lua_pushnumber(L, n.doubleValue);
        return;
    }
    lua_pushstring(L, [[v description] UTF8String]);
}
static int l_qdPut(lua_State *L) {
    NSString *name = qdSelfName(L);
    NSString *key = [NSString stringWithUTF8String:luaL_checkstring(L, 2)];
    NSMutableDictionary *dict = qdLoad(name);
    dict[key] = qdLuaToStore(L, 3);
    lua_pushboolean(L, qdSave(name, dict));
    return 1;
}
static int l_qdGet(lua_State *L) {
    NSString *key = [NSString stringWithUTF8String:luaL_checkstring(L, 2)];
    qdPushStore(L, qdLoad(qdSelfName(L))[key]);
    return 1;
}
static int l_qdGetString(lua_State *L) {
    NSString *key = [NSString stringWithUTF8String:luaL_checkstring(L, 2)];
    id v = qdLoad(qdSelfName(L))[key];
    if (!v || v == [NSNull null]) { lua_pushnil(L); return 1; }
    lua_pushstring(L, [[v description] UTF8String]);
    return 1;
}
static int l_qdGetNumber(lua_State *L) {
    NSString *key = [NSString stringWithUTF8String:luaL_checkstring(L, 2)];
    id v = qdLoad(qdSelfName(L))[key];
    if ([v isKindOfClass:[NSNumber class]]) { lua_pushnumber(L, [v doubleValue]); return 1; }
    if ([v isKindOfClass:[NSString class]]) { lua_pushnumber(L, strtod([v UTF8String], NULL)); return 1; }
    lua_pushnil(L); return 1;
}
static int l_qdGetBool(lua_State *L) {
    NSString *key = [NSString stringWithUTF8String:luaL_checkstring(L, 2)];
    id v = qdLoad(qdSelfName(L))[key];
    if ([v isKindOfClass:[NSNumber class]]) { lua_pushboolean(L, [(NSNumber *)v boolValue]); return 1; }
    if ([v isKindOfClass:[NSString class]]) {
        lua_pushboolean(L, [v isEqualToString:@"true"] || [v isEqualToString:@"1"] || [v boolValue]);
        return 1;
    }
    lua_pushnil(L); return 1;
}
static int l_qdContains(lua_State *L) {
    NSString *key = [NSString stringWithUTF8String:luaL_checkstring(L, 2)];
    lua_pushboolean(L, qdLoad(qdSelfName(L))[key] != nil);
    return 1;
}
static int l_qdRemove(lua_State *L) {
    NSString *name = qdSelfName(L);
    NSString *key = [NSString stringWithUTF8String:luaL_checkstring(L, 2)];
    NSMutableDictionary *dict = qdLoad(name);
    if (!dict[key]) { lua_pushboolean(L, 0); return 1; }
    [dict removeObjectForKey:key];
    lua_pushboolean(L, qdSave(name, dict));
    return 1;
}
static int l_qdSize(lua_State *L) {
    lua_pushinteger(L, (lua_Integer)qdLoad(qdSelfName(L)).count);
    return 1;
}
static int l_qdClear(lua_State *L) {
    NSString *name = qdSelfName(L);
    NSMutableDictionary *dict = qdLoad(name);
    [dict removeAllObjects];
    lua_pushboolean(L, qdSave(name, dict));
    return 1;
}
static int l_qdCommit(lua_State *L) {           // put 即时落盘，commit 恒成功
    lua_pushboolean(L, 1);
    return 1;
}
static int l_qdGetType(lua_State *L) {
    NSString *key = [NSString stringWithUTF8String:luaL_checkstring(L, 2)];
    id v = qdLoad(qdSelfName(L))[key];
    if (!v) { lua_pushstring(L, "unknown"); return 1; }
    if (v == [NSNull null]) { lua_pushstring(L, "null"); return 1; }
    if ([v isKindOfClass:[NSString class]]) { lua_pushstring(L, "string"); return 1; }
    if ([v isKindOfClass:[NSNumber class]]) {
        if (strcmp([(NSNumber *)v objCType], "c") == 0 || strcmp([(NSNumber *)v objCType], "B") == 0) {
            lua_pushstring(L, "bool"); return 1;
        }
        lua_pushstring(L, [(NSNumber *)v doubleValue] == floor([(NSNumber *)v doubleValue]) ? "int" : "double");
        return 1;
    }
    lua_pushstring(L, "unknown");
    return 1;
}
static int l_qdPrint(lua_State *L) {
    NSMutableDictionary *dict = qdLoad(qdSelfName(L));
    NSMutableString *out = maOut(L);
    for (NSString *k in dict) {
        [out appendFormat:@"%@ = %@\n", k, dict[k]];
    }
    return 0;
}
static int l_qdOpen(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);
    if (!name[0]) { lua_pushnil(L); return 1; }
    lua_createtable(L, 0, 16);
    lua_pushstring(L, name); lua_setfield(L, -2, "_name");
    lua_pushcfunction(L, l_qdPut);        lua_setfield(L, -2, "put");
    lua_pushcfunction(L, l_qdGet);        lua_setfield(L, -2, "get");
    lua_pushcfunction(L, l_qdGetString);  lua_setfield(L, -2, "getString");
    lua_pushcfunction(L, l_qdGetNumber);  lua_setfield(L, -2, "getInt");
    lua_pushcfunction(L, l_qdGetNumber);  lua_setfield(L, -2, "getDouble");
    lua_pushcfunction(L, l_qdGetBool);    lua_setfield(L, -2, "getBool");
    lua_pushcfunction(L, l_qdContains);   lua_setfield(L, -2, "contains");
    lua_pushcfunction(L, l_qdRemove);     lua_setfield(L, -2, "remove");
    lua_pushcfunction(L, l_qdSize);       lua_setfield(L, -2, "size");
    lua_pushcfunction(L, l_qdClear);      lua_setfield(L, -2, "clear");
    lua_pushcfunction(L, l_qdCommit);     lua_setfield(L, -2, "commit");
    lua_pushcfunction(L, l_qdGetType);    lua_setfield(L, -2, "getType");
    lua_pushcfunction(L, l_qdPrint);      lua_setfield(L, -2, "print");
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

// ---------------- 日志控制台（设备端 logdir/log.txt） ----------------
static NSString *maLogPath(void) { return [MatisuLogDir() stringByAppendingPathComponent:@"log.txt"]; }

// ---- 引擎输出日志（logdir/engine.log）：所有 print 镜像落盘，供 PC IDE 日志流拉取 ----
// 与 Android 侧 EngineLog 对齐：追加写、超 256KB 时保留尾部 128KB 截断。
// 每次追加自动加 [HH:mm:ss.SSS] 时间戳（IDE 端直接显示，时间=设备侧真实时刻）。
static NSString *maEngineLogPath(void) { return [MatisuLogDir() stringByAppendingPathComponent:@"engine.log"]; }
static void maEngineLogAppend(NSString *text) {
    if (!text.length) return;
    @autoreleasepool {
        NSDateFormatter *tsf = [[NSDateFormatter alloc] init];
        tsf.dateFormat = @"HH:mm:ss.SSS";
        text = [NSString stringWithFormat:@"[%@] %@", [tsf stringFromDate:[NSDate date]], text];
        NSString *p = maEngineLogPath();
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:[p stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        NSData *d = [text dataUsingEncoding:NSUTF8StringEncoding];
        if (![fm fileExistsAtPath:p]) {
            [d writeToFile:p atomically:YES];
            return;
        }
        NSDictionary *attr = [fm attributesOfItemAtPath:p error:nil];
        unsigned long long sz = [attr fileSize];
        if (sz > 256 * 1024) {
            NSFileHandle *rh = [NSFileHandle fileHandleForReadingAtPath:p];
            [rh seekToFileOffset:sz - 128 * 1024];
            NSData *tail = [rh readDataToEndOfFile];
            [rh closeFile];
            [tail writeToFile:p atomically:YES];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        [fh seekToEndOfFile];
        [fh writeData:d];
        [fh closeFile];
    }
}
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

// ---------------- 动态 UI（showUI，WKWebView 渲染，见 ShowUI.m） ----------------
// showUI(JSON字符串 或 table)：确认返回 1,值1,值2...；取消返回 0
static int l_showUI(lua_State *L) {
    NSString *json = nil;
    if (lua_isstring(L, 1)) {
        const char *s = lua_tostring(L, 1);
        if (s && s[0]) json = [NSString stringWithUTF8String:s];
    } else if (lua_istable(L, 1)) {
        lua_getglobal(L, "jsonLib");
        if (lua_istable(L, -1)) {
            lua_getfield(L, -1, "encode");
            lua_pushvalue(L, 1);
            if (lua_pcall(L, 1, 1, 0) == LUA_OK) {
                const char *enc = lua_tostring(L, -1);
                if (enc) json = [NSString stringWithUTF8String:enc];
            } else lua_pop(L, 1);   // 错误对象
        }
        lua_pop(L, 1);   // jsonLib 表
    }
    NSDictionary *ut = nil;
    if (json.length) {
        NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
        id o = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if ([o isKindOfClass:[NSDictionary class]]) ut = o;
    }
    if (!ut) { lua_pushinteger(L, 0); return 1; }
    NSArray<NSString *> *out = MatisuShowUIRun(ut);
    for (NSString *v in out) lua_pushstring(L, v.UTF8String);
    return (int)out.count;
}
// closeWindow：无回调模式下窗口自动关闭，保留兼容
static int l_closeWindow(lua_State *L) {
    lua_pushboolean(L, 1);
    return 1;
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
// findStr(x1,y1,x2,y2, "a|b|c") -> ret(命中序号1-based), x, y；未命中 0,-1,-1（对齐官方：多关键词 | 分隔）
static int l_findStr(lua_State *L) {
    NSString *spec = [NSString stringWithUTF8String:luaL_checkstring(L, 5)];
    NSArray<MAOcrItem*> *items = MatisuOcrRegion((int)luaL_optinteger(L, 1, 0), (int)luaL_optinteger(L, 2, 0),
                                                 (int)luaL_optinteger(L, 3, 0), (int)luaL_optinteger(L, 4, 0));
    NSArray<NSString *> *keys = [spec componentsSeparatedByString:@"|"];
    int idx = 0;
    for (MAOcrItem *it in items) {
        for (NSString *k in keys) {
            if (k.length && [it.text containsString:k]) {
                lua_pushinteger(L, idx + 1);
                lua_pushinteger(L, it.x + it.w / 2);
                lua_pushinteger(L, it.y + it.h / 2);
                return 3;
            }
        }
        idx++;
    }
    lua_pushinteger(L, 0);
    lua_pushinteger(L, -1);
    lua_pushinteger(L, -1);
    return 3;
}

static int l_readPasteboard(lua_State *L) {
    NSString *s = MatisuReadPasteboard();
    lua_pushstring(L, s.UTF8String);
    return 1;
}

// ---------------- OCR 官方别名层（ocr/ocrj/findStrEx + *New 带字库索引变体，单引擎忽略 index） ----------------
static int l_ocrAliasText(lua_State *L) { return l_ocrText(L); }
static int l_ocrAliasEx(lua_State *L) { return l_ocrTextEx(L); }
static int l_ocrNew(lua_State *L) { lua_remove(L, 1); return l_ocrText(L); }       // (index,x1,y1,x2,y2,...)
static int l_ocrjNew(lua_State *L) { lua_remove(L, 1); return l_ocrTextEx(L); }
static int l_findStrNew(lua_State *L) { lua_remove(L, 1); return l_findStr(L); }
// findStrEx(x1,y1,x2,y2,text) -> 全部命中 {text=,x=,y=,w=,h=} 表
static int l_findStrExImpl(lua_State *L) {
    NSString *needle = [NSString stringWithUTF8String:luaL_checkstring(L, 5)];
    NSArray<MAOcrItem *> *items = MatisuOcrRegion((int)luaL_optinteger(L, 1, 0), (int)luaL_optinteger(L, 2, 0),
                                                  (int)luaL_optinteger(L, 3, 0), (int)luaL_optinteger(L, 4, 0));
    lua_createtable(L, 0, 0);
    int n = 0;
    for (MAOcrItem *it in items) {
        if (![it.text containsString:needle]) continue;
        lua_createtable(L, 0, 5);
        lua_pushstring(L, it.text.UTF8String); lua_setfield(L, -2, "text");
        lua_pushinteger(L, it.x); lua_setfield(L, -2, "x");
        lua_pushinteger(L, it.y); lua_setfield(L, -2, "y");
        lua_pushinteger(L, it.w); lua_setfield(L, -2, "w");
        lua_pushinteger(L, it.h); lua_setfield(L, -2, "h");
        lua_seti(L, -2, ++n);
    }
    return 1;
}
static int l_findStrEx(lua_State *L) { return l_findStrExImpl(L); }
static int l_findStrExNew(lua_State *L) { lua_remove(L, 1); return l_findStrExImpl(L); }

// ---------------- 文件 IO（官方 io 语义：相对路径拼工作目录） ----------------
static NSString *l_pathResolve(lua_State *L, int idx) {
    const char *s = luaL_checkstring(L, idx);
    NSString *p = [NSString stringWithUTF8String:s];
    if (![p hasPrefix:@"/"]) p = [MatisuWorkDir() stringByAppendingPathComponent:p];
    return p;
}
static int l_readFile(lua_State *L) {
    NSString *p = l_pathResolve(L, 1);
    NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
    if (s) { lua_pushstring(L, s.UTF8String); return 1; }
    NSData *d = [NSData dataWithContentsOfFile:p];   // 非UTF8按二进制读
    if (d) { lua_pushlstring(L, (const char *)d.bytes, d.length); return 1; }
    lua_pushnil(L); return 1;
}
static int l_writeFile(lua_State *L) {
    NSString *p = l_pathResolve(L, 1);
    size_t len; const char *s = luaL_checklstring(L, 2, &len);
    BOOL append = lua_toboolean(L, 3);
    if (!append) {
        BOOL ok = [[NSData dataWithBytes:s length:len] writeToFile:p atomically:YES];
        lua_pushboolean(L, ok); return 1;
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
    if (!fh) {
        if (![[NSFileManager defaultManager] createFileAtPath:p contents:[NSData data] attributes:nil]) {
            lua_pushboolean(L, 0); return 1;
        }
        fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (!fh) { lua_pushboolean(L, 0); return 1; }
    }
    [fh seekToEndOfFile];
    [fh writeData:[NSData dataWithBytes:s length:len]];
    [fh closeFile];
    lua_pushboolean(L, 1); return 1;
}
static int l_fileSize(lua_State *L) {
    NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:l_pathResolve(L, 1) error:nil];
    lua_pushinteger(L, at ? (lua_Integer)[at fileSize] : -1);
    return 1;
}
static int l_fileExist(lua_State *L) {
    lua_pushboolean(L, [[NSFileManager defaultManager] fileExistsAtPath:l_pathResolve(L, 1)]);
    return 1;
}
static int l_mkdir(lua_State *L) {
    NSError *err = nil;
    BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:l_pathResolve(L, 1)
                                        withIntermediateDirectories:YES attributes:nil error:&err];
    lua_pushboolean(L, ok); return 1;
}
static int l_delfile(lua_State *L) {
    NSError *err = nil;
    BOOL ok = [[NSFileManager defaultManager] removeItemAtPath:l_pathResolve(L, 1) error:&err];
    lua_pushboolean(L, ok); return 1;
}
static int l_listDir(lua_State *L) {
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:l_pathResolve(L, 1) error:nil];
    lua_createtable(L, (int)names.count, 0);
    for (NSUInteger i = 0; i < names.count; i++) {
        lua_pushstring(L, [names[i] UTF8String]);
        lua_seti(L, -2, (lua_Integer)i + 1);
    }
    return 1;
}
// zip/unZip：iOS 暂不支持（官方语义保留，返回 false）
static int l_zip(lua_State *L) { lua_pushboolean(L, 0); return 1; }
static int l_unZip(lua_State *L) { lua_pushboolean(L, 0); return 1; }

// ---------------- 时间 ----------------
static int64_t gTickCountBase = 0;   // registerAll 时设为引擎启动时刻
static int l_systemTime(lua_State *L) {
    lua_pushinteger(L, (lua_Integer)([[NSDate date] timeIntervalSince1970] * 1000.0));
    return 1;
}
static int l_tickCount(lua_State *L) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    int64_t now = ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
    if (gTickCountBase == 0) gTickCountBase = now;
    lua_pushinteger(L, now - gTickCountBase);
    return 1;
}
// getNetWorkTime：同步取 HTTP Date 头（5s 超时），失败回退系统时间；输出 yyyy-MM-dd_HH-mm-ss 本地时区
static int l_getNetWorkTime(lua_State *L) {
    NSDate *dt = nil;
    @try {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://captive.apple.com/hotspot-detect.html"]];
        req.timeoutInterval = 5.0; req.HTTPMethod = @"HEAD";
        __block NSString *date = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                                     completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            date = [(NSHTTPURLResponse *)r allHeaderFields][@"Date"];
            dispatch_semaphore_signal(sem);
        }];
        [task resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC));
        if (date) {
            NSDateFormatter *f = [[NSDateFormatter alloc] init];
            f.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
            f.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
            f.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss zzz";
            dt = [f dateFromString:date];
        }
    } @catch (NSException *ex) { dt = nil; }
    if (!dt) dt = [NSDate date];
    NSDateFormatter *out = [[NSDateFormatter alloc] init];
    out.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
    lua_pushstring(L, [out stringFromDate:dt].UTF8String);
    return 1;
}

// ---------------- showToast（iOS 无法全局弹窗：进程内 keyWindow 顶部横幅 3s） ----------------
static int l_showToast(lua_State *L) {
    NSString *msg = [NSString stringWithUTF8String:luaL_optstring(L, 1, "")];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = nil;
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]] &&
                sc.activationState == UISceneActivationStateForegroundActive) {
                UIWindowScene *wsc = (UIWindowScene *)sc;
                win = wsc.windows.firstObject;
                if (!win) {
                    win = [[UIWindow alloc] initWithWindowScene:wsc];
                    win.windowLevel = UIWindowLevelAlert + 200;
                }
                break;
            }
        }
        if (!win) return;
        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(20, 80, win.bounds.size.width - 40, 40)];
        lb.text = msg; lb.textAlignment = NSTextAlignmentCenter;
        lb.textColor = UIColor.whiteColor; lb.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
        lb.layer.cornerRadius = 8; lb.clipsToBounds = YES; lb.numberOfLines = 3;
        [win addSubview:lb];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3LL * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [lb removeFromSuperview];
        });
    });
    lua_pushboolean(L, 1); return 1;
}

// ---------------- 系统 getter ----------------
static int l_getWorkPath(lua_State *L) {
    lua_pushstring(L, MatisuWorkDir().UTF8String); return 1;
}
static int l_getPackageName(lua_State *L) {
    lua_pushstring(L, NSBundle.mainBundle.bundleIdentifier.UTF8String); return 1;
}
static int l_getScriptVersion(lua_State *L) {
    pushInfoStr(L, @"CFBundleShortVersionString"); return 1;
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

// ---- 运行后全局变量快照（调试面板变量表）----
// 遍历全局表，过滤标准库/引擎注入符号；value 用类型化表示（table/function 不展开），截断 120 字符。
static NSArray<NSArray<NSString *> *> *maDumpGlobals(lua_State *L) {
    static NSSet *gSkip = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gSkip = [NSSet setWithArray:@[
            @"_G", @"_VERSION", @"assert", @"collectgarbage", @"dofile", @"error", @"getfenv",
            @"getmetatable", @"ipairs", @"load", @"loadfile", @"loadstring", @"next", @"pairs",
            @"pcall", @"print", @"rawequal", @"rawget", @"rawset", @"require", @"select",
            @"setfenv", @"setmetatable", @"tonumber", @"tostring", @"type", @"unpack",
            @"xpcall", @"string", @"table", @"math", @"os", @"io", @"debug", @"coroutine",
            @"package", @"gcinfo", @"newproxy", @"exitScript", @"sleep", @"init",
        ]];
    });
    NSMutableArray<NSArray<NSString *> *> *rows = [NSMutableArray array];
    @autoreleasepool {
        lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
        if (lua_istable(L, -1)) {
            lua_pushnil(L);
            while (lua_next(L, -2) != 0 && rows.count < 100) {
                if (lua_type(L, -2) == LUA_TSTRING) {
                    const char *k = lua_tostring(L, -2);
                    NSString *name = k ? @(k) : @"";
                    if (![gSkip containsObject:name]) {
                        NSString *val;
                        int t = lua_type(L, -1);
                        if (t == LUA_TTABLE) val = @"<table>";
                        else if (t == LUA_TFUNCTION) val = @"<function>";
                        else {
                            luaL_tolstring(L, -1, NULL);
                            const char *s = lua_tostring(L, -1);
                            val = s ? @(s) : @"?";
                            lua_pop(L, 1);
                            if (val.length > 120) val = [[val substringToIndex:120] stringByAppendingString:@"…"];
                        }
                        [rows addObject:@[name, val, @(lua_typename(L, t))]];
                    }
                }
                lua_pop(L, 1);   // 弹 value，留 key 给下次 lua_next
            }
        }
        lua_pop(L, 1);           // 弹全局表
    }
    return rows;
}

// ---------------- 断点调试会话（runfiledbg；状态进程级，跨 18182 连接共享） ----------------
// 线程模型：引擎线程在 line hook 命中断点 → 抓状态 → signal gDbgPauseSem → 等 gDbgResumeSem；
// runfiledbg 处理线程等 gDbgPauseSem（暂停发暂停帧/完成发最终帧）；dbggo/dbgstep/dbgstop 在
// 其他连接上 signal gDbgResumeSem。信号量计数天然吸收「恢复先于等待」的竞态。
dispatch_semaphore_t gDbgPauseSem = nil;
dispatch_semaphore_t gDbgResumeSem = nil;
volatile BOOL gDbgDone = NO;
NSDictionary *gDbgResult = nil;
NSDictionary *gDbgPausedInfo = nil;
static NSMutableArray<NSNumber *> *gDbgLines = nil;   // 断点行号（1 起）
static volatile BOOL gDbgStepOnce = NO;               // 单步标记（dbgstep 置位）
static volatile BOOL gDbgStopReq = NO;                // dbgstop 请求
static volatile BOOL gDbgActive = NO;                 // 调试模式运行中

void MatisuDbgSetBreakpoints(NSArray<NSNumber *> *lines) {
    if (!gDbgLines) gDbgLines = [NSMutableArray array];
    @synchronized(gDbgLines) {
        [gDbgLines setArray:lines ?: @[]];
    }
    maEngineLogAppend([NSString stringWithFormat:@"[dbg] 断点设置: %@\n", lines ?: @[]]);
}

BOOL MatisuDbgGo(void) {
    if (!gDbgActive) return NO;
    gDbgStepOnce = NO;
    dispatch_semaphore_signal(gDbgResumeSem);
    return YES;
}

BOOL MatisuDbgStep(void) {
    if (!gDbgActive) return NO;
    gDbgStepOnce = YES;
    dispatch_semaphore_signal(gDbgResumeSem);
    return YES;
}

BOOL MatisuDbgStop(void) {
    if (!gDbgActive) return NO;
    gDbgStopReq = YES;
    gRunStop = YES;                       // 未暂停时靠 hook 中断
    dispatch_semaphore_signal(gDbgResumeSem);   // 暂停中直接唤醒退出
    return YES;
}

/// runfiledbg 开始前调用：复位会话标记并置 active
void MatisuDbgBeginSession(void) {
    gDbgStepOnce = NO;
    gDbgStopReq = NO;
    gDbgDone = NO;
    gDbgResult = nil;
    gDbgPausedInfo = nil;
    gDbgActive = YES;
}

/// 调试运行结束时调用（后台线程跑完 MatisuLuaRunNamedDbg 后）
void MatisuDbgEndSession(void) {
    gDbgActive = NO;
}

/// 暂停现场抓取：当前行/局部变量/调用栈深度/全局变量快照
static NSDictionary *maDbgCapture(lua_State *L, lua_Debug *ar, NSInteger line) {
    NSMutableArray<NSArray<NSString *> *> *locals = [NSMutableArray array];
    for (int i = 1; ; i++) {
        const char *nm = lua_getlocal(L, ar, i);
        if (!nm) break;
        if (strcmp(nm, "(*temporary)") != 0) {
            const char *v = lua_isstring(L, -1) ? lua_tostring(L, -1) : NULL;
            NSString *val = v ? [NSString stringWithUTF8String:v]
                              : [NSString stringWithFormat:@"<%s>", luaL_typename(L, -1)];
            [locals addObject:@[ @(i).stringValue, [NSString stringWithUTF8String:nm] ?: @"?", val ]];
        }
        lua_pop(L, 1);
    }
    lua_Debug d;
    int depth = 0;
    while (lua_getstack(L, depth, &d)) depth++;
    NSString *src = ar->source ? [NSString stringWithUTF8String:ar->source] : @"";
    return @{ @"paused": @YES, @"line": @(line), @"source": src, @"locals": locals,
              @"globals": maDumpGlobals(L), @"stack": @(depth) };
}

// 调试模式 hook：line 事件查断点/单步；count 事件保留 gRunStop 中断能力（单行死循环无 line 事件）
static void dbgLineHook(lua_State *L, lua_Debug *ar) {
    if (gRunStop) luaL_error(L, "__MATISU_STOP__");
    if (ar->event != LUA_HOOKLINE || !gDbgActive) return;
    lua_getinfo(L, "Sl", ar);
    NSInteger ln = ar->currentline;
    BOOL hit = gDbgStepOnce;
    if (!hit && gDbgLines) {
        @synchronized(gDbgLines) { hit = [gDbgLines containsObject:@(ln)]; }
    }
    if (!hit) return;
    gDbgPausedInfo = maDbgCapture(L, ar, ln);
    gDbgStepOnce = NO;
    dispatch_semaphore_signal(gDbgPauseSem);                  // 通知 handler 发暂停帧
    dispatch_semaphore_wait(gDbgResumeSem, DISPATCH_TIME_FOREVER);   // 等 dbggo/dbgstep/dbgstop
    if (gDbgStopReq) luaL_error(L, "__MATISU_STOP__");
}

static NSDictionary *maRunImpl(NSString *source, NSString *chunkName, BOOL dbg) {
    if (!source) return nil;
    NSString *chunk = chunkName.length ? chunkName : @"=script";
    // 纯文件名加 '@' 前缀（Lua 视作文件名 chunk：错误/行号显示 "main.lua:9:" 而非 [string "..."]）
    if (![chunk hasPrefix:@"="] && ![chunk hasPrefix:@"@"]) chunk = [@"@" stringByAppendingString:chunk];
    NSMutableString *out = [NSMutableString string];
    lua_State *L = luaL_newstate();
    if (!L) return @{ @"ok": @NO, @"output": @"", @"error": @"luaL_newstate failed" };
    luaL_openlibs(L);

    // 输出收集挂 registry
    lua_pushlightuserdata(L, (__bridge void *)out);
    lua_setfield(L, LUA_REGISTRYINDEX, MA_OUT_KEY);

    registerFns(L, l_print);

    // 引擎生命周期日志（镜像进 engine.log，IDE 调试输出可见）
    NSString *disp = [chunk hasPrefix:@"="] || [chunk hasPrefix:@"@"] ? [chunk substringFromIndex:1] : chunk;
    maEngineLogAppend([NSString stringWithFormat:@"开始运行脚本 %@%@\n", disp, dbg ? @"（调试模式）" : @""]);

    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    gRunStop = NO;
    if (dbg) lua_sethook(L, dbgLineHook, LUA_MASKLINE | LUA_MASKCOUNT, 50);   // line 查断点 + count 保 stop
    else     lua_sethook(L, runHook, LUA_MASKCOUNT, 50);                      // stop 命令 → gRunStop → 下一拍中断
    int status = luaL_loadbufferx(L, source.UTF8String, (size_t)[source lengthOfBytesUsingEncoding:NSUTF8StringEncoding], chunk.UTF8String, "t");
    if (status == LUA_OK) status = lua_pcall(L, 0, 0, 0);
    lua_sethook(L, NULL, 0, 0);
    if (status == LUA_OK) {
        r[@"ok"] = @YES;
        r[@"output"] = out;
    } else {
        const char *err = lua_tostring(L, -1);
        NSString *msg = err ? [NSString stringWithUTF8String:err] : @"unknown error";
        if ([msg containsString:@"__MATISU_STOP__"]) {
            // stop 命令中断：视为正常结束
            r[@"ok"] = @YES;
            r[@"stopped"] = @YES;
            r[@"output"] = out;
            maEngineLogAppend(@"脚本已停止\n");
        } else if ([msg containsString:@"__MATISU_EXIT__"]) {
            // exitScript() 主动结束：视为正常结束（对齐原版语义）
            r[@"ok"] = @YES;
            r[@"output"] = out;
        } else {
            r[@"ok"] = @NO;
            r[@"output"] = out;
            r[@"error"] = msg;
        }
    }
    maEngineLogAppend(@"脚本停止运行\n");
    r[@"globals"] = maDumpGlobals(L);   // 调试面板变量表：脚本结束后全局变量快照
    lua_close(L);
    return r;
}

NSDictionary* _Nullable MatisuLuaRunNamed(NSString *source, NSString *chunkName) {
    return maRunImpl(source, chunkName, NO);
}

/// 调试模式运行：line hook 命中断点暂停，ControlServer 的 runfiledbg 负责组帧
NSDictionary* _Nullable MatisuLuaRunNamedDbg(NSString *source, NSString *chunkName) {
    return maRunImpl(source, chunkName, YES);
}

NSDictionary* _Nullable MatisuLuaRun(NSString *source) {
    return MatisuLuaRunNamed(source, @"=script");
}

// ============================================================
// 常驻脚本服务态（单实例）+ 脚本目录管理
// ============================================================
#import <pthread.h>

static lua_State *gSvcL = NULL;
static volatile BOOL gSvcRunning = NO;
static pthread_t gSvcTid;
static NSMutableString *gSvcOut = nil;
static NSLock *gSvcOutLock = nil;

NSString* _Nonnull MatisuScriptDir(void) {
    return MatisuRunScriptsDir();   // <root>/run/脚本（路径中心统一收口）
}

// 常驻 state 的 print 走共享输出（加锁）
static int l_printSvc(lua_State *L) {
    if (!gSvcOutLock) gSvcOutLock = [NSLock new];
    if (!gSvcOut) gSvcOut = [NSMutableString string];
    int n = lua_gettop(L);
    lua_getglobal(L, "tostring");
    NSMutableString *line = [NSMutableString string];
    for (int i = 1; i <= n; i++) {
        lua_pushvalue(L, -1);
        lua_pushvalue(L, i);
        lua_call(L, 1, 1);
        const char *s = lua_tostring(L, -1);
        if (i > 1) [line appendString:@"\t"];
        if (s) [line appendString:[NSString stringWithUTF8String:s] ?: @"?"];
        lua_pop(L, 1);
    }
    [line appendString:@"\n"];
    [gSvcOutLock lock];
    [gSvcOut appendString:line];
    [gSvcOutLock unlock];
    maEngineLogAppend(maPrintMirror(L, line));   // 镜像落盘：IDE 日志流
    return 0;
}

// 中断 hook：stop 置位后抛错终止脚本
static void svcHook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    if (gSvcStop) luaL_error(L, "__MATISU_STOP__");
}

// one-shot(F5) 中断 hook：由 MatisuLuaRunNamed 挂载，stop 命令置 gRunStop 后触发
static void runHook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    if (gRunStop) luaL_error(L, "__MATISU_STOP__");
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

void MatisuLuaRunStop(void) {
    gRunStop = YES;   // one-shot(F5)：hook / sleep 切片下一拍触发 __MATISU_STOP__
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
// 首启同步到 <数据区>/run/脚本/（mobile 可写），以 bundle 内版本为准覆盖同名文件。
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

// 启动入口解析：run/entry.json 的 lc_entry 优先（脚本包形态），
// 没有则退化 run/脚本/autorun.lua（IDE 直传形态）。
NSString* _Nullable MatisuEntryScriptSource(void) {
    NSData *d = [NSData dataWithContentsOfFile:[MatisuRunDir() stringByAppendingPathComponent:@"entry.json"]];
    if (d) {
        id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        NSString *lc = [j isKindOfClass:NSDictionary.class] ? j[@"lc_entry"] : nil;
        if (lc.length && ![lc containsString:@".."]) {
            NSString *src = [NSString stringWithContentsOfFile:[MatisuRunDir() stringByAppendingPathComponent:lc]
                                                      encoding:NSUTF8StringEncoding error:nil];
            if (src.length) return src;
        }
    }
    return [NSString stringWithContentsOfFile:[MatisuScriptDir() stringByAppendingPathComponent:@"autorun.lua"]
                                     encoding:NSUTF8StringEncoding error:nil];
}

void MatisuLuaAutoRun(void) {
    syncBundledScripts();
    NSString *src = MatisuEntryScriptSource();
    if (src.length) {
        BOOL ok = MatisuLuaStart(src);
        NSLog(@"[MatisuAuto] entry script %@", ok ? @"started" : @"start failed");
    }
}

// FNS 表共享注册（one-shot 用 l_print，常驻用 l_printSvc）
// strutils：两端同源 Lua 实现（与 Android LuaEngine.kt STRUTILS_LUA 保持逐字一致）
static const char *STRUTILS_LUA =
    "strutils = {}\n"
    "function strutils.bin2Hex(data, ishex)\n"
    "  data = tostring(data or \"\")\n"
    "  local parts = {}\n"
    "  for i = 1, #data do\n"
    "    local b = string.byte(data, i)\n"
    "    if ishex then parts[i] = string.format(\"%02x\", b)\n"
    "    else parts[i] = tostring(b) end\n"
    "  end\n"
    "  return table.concat(parts, ishex and \"\" or \" \")\n"
    "end\n"
    "function strutils.split(str, delimiter, limit)\n"
    "  str = tostring(str or \"\")\n"
    "  delimiter = delimiter == nil and \" \" or tostring(delimiter)\n"
    "  limit = tonumber(limit) or 0\n"
    "  local out = {}\n"
    "  if delimiter == \"\" then\n"
    "    for i = 1, #str do out[i] = string.sub(str, i, i) end\n"
    "    return out\n"
    "  end\n"
    "  local pos = 1\n"
    "  while true do\n"
    "    if limit > 0 and #out >= limit then break end\n"
    "    local s, e = string.find(str, delimiter, pos, true)\n"
    "    if not s then break end\n"
    "    out[#out + 1] = string.sub(str, pos, s - 1)\n"
    "    pos = e + 1\n"
    "  end\n"
    "  out[#out + 1] = string.sub(str, pos)\n"
    "  return out\n"
    "end\n"
    "function strutils.trim(s)\n"
    "  return (tostring(s or \"\"):gsub(\"^%s+\", \"\"):gsub(\"%s+$\", \"\"))\n"
    "end\n"
    "function strutils.replace(s, a, b)\n"
    "  s = tostring(s or \"\"); a = tostring(a or \"\"); b = tostring(b or \"\")\n"
    "  if a == \"\" then return s end\n"
    "  local out, pos = {}, 1\n"
    "  while true do\n"
    "    local i, j = string.find(s, a, pos, true)\n"
    "    if not i then break end\n"
    "    out[#out + 1] = string.sub(s, pos, i - 1) .. b\n"
    "    pos = j + 1\n"
    "  end\n"
    "  out[#out + 1] = string.sub(s, pos)\n"
    "  return table.concat(out)\n"
    "end\n"
    "function strutils.startswith(s, p)\n"
    "  s = tostring(s or \"\"); p = tostring(p or \"\")\n"
    "  return string.sub(s, 1, #p) == p\n"
    "end\n"
    "function strutils.endswith(s, p)\n"
    "  s = tostring(s or \"\"); p = tostring(p or \"\")\n"
    "  if p == \"\" then return true end\n"
    "  return string.sub(s, -#p) == p\n"
    "end\n"
    "function strutils.upper(s) return string.upper(tostring(s or \"\")) end\n"
    "function strutils.lower(s) return string.lower(tostring(s or \"\")) end\n";

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
        { "MD5", l_MD5 }, { "sha1", l_sha1 }, { "encodeBase64", l_encodeBase64 }, { "decodeBase64", l_decodeBase64 },
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
        // OCR 官方别名层（2026-09-06 对齐官方文档）
        { "ocr", l_ocrAliasText }, { "ocrj", l_ocrAliasEx },
        { "ocrNew", l_ocrNew }, { "ocrjNew", l_ocrjNew },
        { "findStrEx", l_findStrEx }, { "findStrNew", l_findStrNew }, { "findStrExNew", l_findStrExNew },
        // 文件 IO（官方 io 语义）
        { "readFile", l_readFile }, { "writeFile", l_writeFile }, { "fileSize", l_fileSize },
        { "fileExist", l_fileExist }, { "mkdir", l_mkdir }, { "delfile", l_delfile },
        { "listDir", l_listDir }, { "zip", l_zip }, { "unZip", l_unZip },
        // 时间 / toast / 系统 getter
        { "systemTime", l_systemTime }, { "tickCount", l_tickCount }, { "getNetWorkTime", l_getNetWorkTime },
        { "showToast", l_showToast },
        { "getWorkPath", l_getWorkPath }, { "getPackageName", l_getPackageName },
        { "getScriptVersion", l_getScriptVersion },
        // 动态 UI（WKWebView 渲染，与 Android 同构）
        { "showUI", l_showUI }, { "closeWindow", l_closeWindow },
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
    // cryptLib（AES/RSA）+ QDictionary（键值字典）
    lua_createtable(L, 0, 6);
    lua_pushcfunction(L, l_cryptAes);       lua_setfield(L, -2, "aes_crypt");
    lua_pushcfunction(L, l_cryptAesKeygen); lua_setfield(L, -2, "aes_keygen");
    lua_pushcfunction(L, l_cryptAesIvgen);  lua_setfield(L, -2, "aes_ivgen");
    lua_pushcfunction(L, l_cryptRsaKeygen); lua_setfield(L, -2, "rsa_generate_key");
    lua_pushcfunction(L, l_cryptRsaEncrypt); lua_setfield(L, -2, "rsa_encrypt");
    lua_pushcfunction(L, l_cryptRsaDecrypt); lua_setfield(L, -2, "rsa_decrypt");
    lua_setglobal(L, "cryptLib");
    lua_createtable(L, 0, 1);
    lua_pushcfunction(L, l_qdOpen); lua_setfield(L, -2, "open");
    lua_setglobal(L, "QDictionary");
    lua_pushcfunction(L, printFn);
    lua_setglobal(L, "print");
    // strutils（两端同源 Lua 实现）
    luaL_dostring(L, STRUTILS_LUA);
    for (int i = 0; FNS[i].name; i++) {
        lua_pushcfunction(L, FNS[i].fn);
        lua_setglobal(L, FNS[i].name);
    }
}
