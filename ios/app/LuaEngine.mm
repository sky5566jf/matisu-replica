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
#import <UIKit/UIKit.h>
#import <unistd.h>

// lua 官方头无 extern "C" 守卫（lua.hpp 在 etc/ 未 vendor），C++ 侧自行包裹
extern "C" {
#import "lua/lua.h"
#import "lua/lauxlib.h"
#import "lua/lualib.h"
}

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

NSDictionary* _Nullable MatisuLuaRun(NSString *source) {
    if (!source) return nil;
    NSMutableString *out = [NSMutableString string];
    lua_State *L = luaL_newstate();
    if (!L) return @{ @"ok": @NO, @"output": @"", @"error": @"luaL_newstate failed" };
    luaL_openlibs(L);

    // 输出收集挂 registry
    lua_pushlightuserdata(L, (__bridge void *)out);
    lua_setfield(L, LUA_REGISTRYINDEX, MA_OUT_KEY);

    static const struct { const char *name; lua_CFunction fn; } FNS[] = {
        { "print", l_print },
        { "tap", l_tap }, { "longTap", l_longTap }, { "swipe", l_swipe },
        { "touchDown", l_touchDown }, { "touchMove", l_touchMove }, { "touchUp", l_touchUp },
        { "keyPress", l_keyPress }, { "inputText", l_inputText },
        { "getDisplaySize", l_getDisplaySize },
        { "getPixelColor", l_getPixelColor },
        { "sleep", l_sleep }, { "mSleep", l_mSleep },
        { NULL, NULL },
    };
    for (int i = 0; FNS[i].name; i++) {
        lua_pushcfunction(L, FNS[i].fn);
        lua_setglobal(L, FNS[i].name);
    }

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
