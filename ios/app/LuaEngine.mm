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
#import <UIKit/UIKit.h>
#import <unistd.h>

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
            if (isArr && maxn == cnt) {
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
        r[@"ok"] = @NO;
        r[@"output"] = out;
        r[@"error"] = err ? [NSString stringWithUTF8String:err] : @"unknown error";
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
    lua_State *L = luaL_newstate();
    if (L) {
        luaL_openlibs(L);
        registerFns(L, l_printSvc);
        lua_sethook(L, svcHook, LUA_MASKCOUNT, 50);
        int status = luaL_loadbufferx(L, source.UTF8String,
                                      (size_t)[source lengthOfBytesUsingEncoding:NSUTF8StringEncoding], "=service", "t");
        if (status == LUA_OK) status = lua_pcall(L, 0, 0, 0);
        if (status != LUA_OK) {
            const char *err = lua_tostring(L, -1);
            NSString *msg = err ? [NSString stringWithUTF8String:err] : @"unknown";
            if (![msg containsString:@"__MATISU_STOP__"]) {
                [gSvcOutLock lock];
                [gSvcOut appendFormat:@"[service error] %@\n", msg];
                [gSvcOutLock unlock];
            }
        }
        lua_close(L);
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

void MatisuLuaAutoRun(void) {
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
        { "findMultiColor", l_findMultiColor },
        { "httpGet", l_httpGet }, { "httpPost", l_httpPost },
        { "MD5", l_MD5 }, { "encodeBase64", l_encodeBase64 }, { "decodeBase64", l_decodeBase64 },
        { "readPasteboard", l_readPasteboard }, { "writePasteboard", l_writePasteboard },
        { "runApp", l_runApp }, { "openUrl", l_openUrl },
        { NULL, NULL },
    };
    // jsonLib 表（encode/decode）
    lua_createtable(L, 0, 2);
    lua_pushcfunction(L, l_jsonEncode); lua_setfield(L, -2, "encode");
    lua_pushcfunction(L, l_jsonDecode); lua_setfield(L, -2, "decode");
    lua_setglobal(L, "jsonLib");
    lua_pushcfunction(L, printFn);
    lua_setglobal(L, "print");
    for (int i = 0; FNS[i].name; i++) {
        lua_pushcfunction(L, FNS[i].fn);
        lua_setglobal(L, FNS[i].name);
    }
}
