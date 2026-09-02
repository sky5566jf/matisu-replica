#import "ControlServer.h"
#import "TouchInject.h"
#import "ScreenShot.h"
#import "AXNodeDump.h"
#import "DeviceInfo.h"
#import "LuaEngine.h"
#import "ColorFind.h"
#import "SysUtil.h"
#import "PackageManager.h"
#import "MatisuPaths.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <pthread.h>
#import <string.h>

// 简易文本协议（每行一条指令），PC 端 MatisuAuto 运行器下发：
//   tap x y
//   swipe x1 y1 x2 y2 [duration_ms]
//   down finger x y
//   move finger x y
//   up finger x y
//   screencap            -> 回传 [4字节大端长度][PNG 字节]
//   uinode               -> 回传 [4字节大端长度][UTF-8 JSON 字节]（Android 同构节点数组）
//   devinfo              -> 回传 [4字节大端长度][UTF-8 JSON 字节]（真实设备信息）
// 除 screencap/uinode 外，指令执行后统一回传 "OK\n"（长度前缀包裹）。
// 长度前缀协议保证 PC 端能精确读到二进制帧，不受换行干扰。

static void sendLE(int cli, const void *data, NSUInteger len) {
    // 4 字节大端长度 + 负载
    uint8_t head[4] = {
        (uint8_t)((len >> 24) & 0xFF), (uint8_t)((len >> 16) & 0xFF),
        (uint8_t)((len >> 8) & 0xFF),  (uint8_t)(len & 0xFF),
    };
    ssize_t w = write(cli, head, 4);
    if (w != 4) return;
    if (len > 0 && data) write(cli, data, len);
}

static void sendOK(int cli) {
    const char *ok = "OK\n";
    sendLE(cli, ok, strlen(ok));
}

// 优先走 SpringBoard tweak 的节点服务（127.0.0.1:18183，XXTouch 同款架构，
// SpringBoard 进程内取前台 App 无障碍树，绕过普通进程 -25211 限制）；
// 取不到返回 nil，调用方回退本进程实现。
static NSData* queryTweak(const char *cmd, NSTimeInterval timeout) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return nil;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(18183);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(s, (struct sockaddr*)&addr, sizeof(addr)) < 0) { close(s); return nil; }
    struct timeval tv = { (time_t)timeout, 0 };
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    write(s, cmd, strlen(cmd));
    write(s, "\n", 1);
    uint8_t head[4];
    ssize_t got = 0;
    while (got < 4) {
        ssize_t r = read(s, head + got, 4 - got);
        if (r <= 0) { close(s); return nil; }
        got += r;
    }
    NSUInteger len = ((NSUInteger)head[0] << 24) | ((NSUInteger)head[1] << 16) |
                     ((NSUInteger)head[2] << 8) | (NSUInteger)head[3];
    if (len == 0 || len > 16 * 1024 * 1024) { close(s); return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:len];
    got = 0;
    while (got < len) {
        ssize_t r = read(s, (uint8_t*)data.mutableBytes + got, len - got);
        if (r <= 0) { close(s); return nil; }
        got += r;
    }
    close(s);
    return data;
}

// 从累积缓冲取出一条完整指令（malloc 返回，调用方 free）。
// 普通指令 = 一行文本（\n 结尾，\r 可选）。
// installpkg 为二进制帧：installpkg <b64(包名)> <size>\n<size 字节 raw zip>——
// 帧体没收齐时返回 NULL 等更多数据；收齐则在本函数内直接处理并响应，
// 返回空串（调用方跳过）。（老协议 4096 定长 buf + strtok 会把跨包的长行截断，
// 且无法承载二进制，故改累积缓冲。）
static char *MANextCommand(int cli, NSMutableData *acc) {
    const uint8_t *bytes = (const uint8_t *)acc.bytes;
    NSUInteger len = acc.length;
    for (NSUInteger i = 0; i < len; i++) {
        if (bytes[i] != '\n') continue;
        NSUInteger lineLen = (i > 0 && bytes[i - 1] == '\r') ? i - 1 : i;
        if (lineLen > 11 && memcmp(bytes, "installpkg ", 11) == 0) {
            NSString *hdr = [[NSString alloc] initWithBytes:bytes length:lineLen encoding:NSUTF8StringEncoding];
            NSArray *parts = [hdr componentsSeparatedByString:@" "];
            if (parts.count == 3) {
                unsigned long long sz = strtoull([parts[2] UTF8String], NULL, 10);
                if (sz > 0 && sz <= 64ULL * 1024 * 1024) {
                    if (len < i + 1 + sz) return NULL;   // 帧体未到齐，等下一拨
                    NSData *nameD = [[NSData alloc] initWithBase64EncodedString:parts[1] options:0];
                    NSString *name = nameD ? [[NSString alloc] initWithData:nameD encoding:NSUTF8StringEncoding] : nil;
                    NSData *payload = [NSData dataWithBytes:bytes + i + 1 length:(NSUInteger)sz];
                    int files = 0; NSString *err = nil;
                    BOOL ok = name && MatisuInstallPackage(name, payload, &files, &err);
                    NSDictionary *r = ok ? @{ @"ok": @YES, @"files": @(files) }
                                         : @{ @"ok": @NO, @"error": (err ?: @"bad frame") };
                    NSData *j = [NSJSONSerialization dataWithJSONObject:r options:0 error:nil];
                    sendLE(cli, j ? j.bytes : NULL, j ? j.length : 0);
                    NSLog(@"[MatisuAuto] installpkg %@ -> %@", name, ok ? @"OK" : err);
                    [acc replaceBytesInRange:NSMakeRange(0, i + 1 + (NSUInteger)sz) withBytes:NULL length:0];
                    return strdup("");   // 已响应，调用方跳过
                }
            }
            // 畸形 installpkg 头：按普通行落 unknown
        }
        char *line = (char *)malloc(lineLen + 1);
        memcpy(line, bytes, lineLen);
        line[lineLen] = 0;
        [acc replaceBytesInRange:NSMakeRange(0, i + 1) withBytes:NULL length:0];
        return line;
    }
    return NULL;
}

// 连接处理（每连接独立线程）：run/runfile 是同步执行，脚本含无限循环时
// 单线程 accept 循环会被整体堵死——看门狗探活失败会误杀重启（2026-09-02 真机实证：
// runfile 一个 while(true) 脚本后整个 :18182 拒连）。one-shot 各自 newstate、
// 常驻服务本就独立线程，触控/截图等子系统此前已与常驻脚本线程并发，不引入新风险类。
static void* MAClientLoop(void* arg) {
    int cli = (int)(intptr_t)arg;
    char buf[4096];
    ssize_t n;
    // 每连接一个 autoreleasepool：screencap/uinode 在非主线程产生大量
    // autoreleased 对象（UIImage/PNG/JSON），无 pool 会累积泄漏直至
    // jetsam per-process-limit 杀进程（真机实证 10 连发即崩）。
    @autoreleasepool {
    NSMutableData *acc = [NSMutableData data];
        while ((n = recv(cli, buf, sizeof(buf), 0)) > 0) {
            [acc appendBytes:buf length:n];
            for (;;) {
                char *line = MANextCommand(cli, acc);
                if (!line) break;
                float x, y, x2, y2, d = 0.2f;
                int f = 0;
                if (!line[0]) {   // installpkg 帧已在 MANextCommand 内响应
                } else if (sscanf(line, "tap %f %f", &x, &y) == 2) {
                    MatisuTouchTap(x, y);
                    NSLog(@"[MatisuAuto] tap %.0f,%.0f", x, y);
                    sendOK(cli);
                } else if (sscanf(line, "swipe %f %f %f %f %f", &x, &y, &x2, &y2, &d) >= 4) {
                    MatisuTouchSwipe(x, y, x2, y2, d);
                    sendOK(cli);
                } else if (sscanf(line, "down %d %f %f", &f, &x, &y) == 3) {
                    MatisuTouchDown(f, x, y);
                    sendOK(cli);
                } else if (sscanf(line, "move %d %f %f", &f, &x, &y) == 3) {
                    MatisuTouchMove(f, x, y);
                    sendOK(cli);
                } else if (sscanf(line, "up %d %f %f", &f, &x, &y) == 3) {
                    MatisuTouchUp(f, x, y);
                    sendOK(cli);
                } else if (strncmp(line, "key ", 4) == 0 && line[4]) {
                    // key <NAME>：HOME/RETURN/DELETE/ESCAPE/TAB/SPACE/方向键等（STHID 键盘注入）
                    MatisuKeyPressName(line + 4);
                    NSLog(@"[MatisuAuto] key %s", line + 4);
                    sendOK(cli);
                } else if (strncmp(line, "keydown ", 8) == 0 && line[8]) {
                    MatisuKeyDownName(line + 8);
                    sendOK(cli);
                } else if (strncmp(line, "keyup ", 6) == 0 && line[6]) {
                    MatisuKeyUpName(line + 6);
                    sendOK(cli);
                } else if (strncmp(line, "input ", 6) == 0 && line[6]) {
                    // input <text>：ASCII 文本逐键注入（中文待 imeLib）
                    MatisuTypeText(line + 6);
                    NSLog(@"[MatisuAuto] input %.40s", line + 6);
                    sendOK(cli);
                } else if (strcmp(line, "screencap") == 0) {
                    NSData *png = MatisuCapturePNG();
                    if (png && png.length) {
                        sendLE(cli, png.bytes, png.length);
                        NSLog(@"[MatisuAuto] screencap -> %lu bytes", (unsigned long)png.length);
                    } else {
                        sendLE(cli, NULL, 0); // 长度 0 表示截图失败
                        NSLog(@"[MatisuAuto] screencap failed");
                    }
                } else if (strcmp(line, "uinode") == 0) {
                    NSData *json = queryTweak("uinode", 5.0);   // 优先 SpringBoard tweak
                    if (!json) json = MatisuDumpNodesJSON();    // 回退本进程 AX
                    if (json && json.length) {
                        sendLE(cli, json.bytes, json.length);
                        NSLog(@"[MatisuAuto] uinode -> %lu bytes", (unsigned long)json.length);
                    } else {
                        sendLE(cli, NULL, 0);
                        NSLog(@"[MatisuAuto] uinode failed (需 accessibility.inspection 授权)");
                    }
                } else if (strncmp(line, "run ", 4) == 0 && line[4]) {
                    // run <base64(lua 源码)>：设备端 Lua 引擎执行（base64 防协议冲突）
                    NSString *b64 = [NSString stringWithUTF8String:line + 4];
                    NSData *src = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
                    NSDictionary *r = src
                        ? MatisuLuaRun([[NSString alloc] initWithData:src encoding:NSUTF8StringEncoding])
                        : @{ @"ok": @NO, @"output": @"", @"error": @"base64 decode failed" };
                    NSData *json = [NSJSONSerialization dataWithJSONObject:r options:0 error:nil];
                    sendLE(cli, json ? json.bytes : NULL, json ? json.length : 0);
                } else if (strncmp(line, "runfile ", 8) == 0 && line[8]) {
                    // runfile <相对路径>：执行 scripts 目录下脚本（one-shot）
                    NSString *f = [MatisuScriptDir() stringByAppendingPathComponent:@(line + 8)];
                    NSString *src = [NSString stringWithContentsOfFile:f encoding:NSUTF8StringEncoding error:nil];
                    NSDictionary *r = src
                        ? MatisuLuaRun(src)
                        : @{ @"ok": @NO, @"output": @"", @"error": [NSString stringWithFormat:@"script not found: %@", @(line + 8)] };
                    NSData *json2 = [NSJSONSerialization dataWithJSONObject:r options:0 error:nil];
                    sendLE(cli, json2 ? json2.bytes : NULL, json2 ? json2.length : 0);
                } else if (strncmp(line, "upload ", 7) == 0 && line[7]) {
                    // upload <b64(相对路径)> <b64(内容)>：写 scripts 目录
                    NSString *rest = [@(line + 7) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    NSRange sp = [rest rangeOfString:@" "];
                    BOOL okw = NO;
                    if (sp.location != NSNotFound) {
                        NSData *pd = [[NSData alloc] initWithBase64EncodedString:[rest substringToIndex:sp.location] options:0];
                        NSData *cd = [[NSData alloc] initWithBase64EncodedString:[rest substringFromIndex:sp.location + 1] options:0];
                        NSString *rel = pd ? [[NSString alloc] initWithData:pd encoding:NSUTF8StringEncoding] : nil;
                        if (rel.length && cd && ![rel containsString:@".."]) {
                            NSString *f = [MatisuScriptDir() stringByAppendingPathComponent:rel];
                            [[NSFileManager defaultManager] createDirectoryAtPath:[f stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
                            okw = [cd writeToFile:f atomically:YES];
                        }
                    }
                    const char *resp = okw ? "OK\n" : "FAIL\n";
                    sendLE(cli, resp, strlen(resp));
                } else if (strcmp(line, "list") == 0) {
                    // list：scripts 目录文件清单（相对路径数组 JSON）
                    NSDirectoryEnumerator *en = [[NSFileManager defaultManager] enumeratorAtPath:MatisuScriptDir()];
                    NSMutableArray *files = [NSMutableArray array];
                    NSString *p2;
                    while ((p2 = [en nextObject])) {
                        if ([[en fileAttributes][NSFileType] isEqualToString:NSFileTypeRegular]) [files addObject:p2];
                    }
                    NSData *json3 = [NSJSONSerialization dataWithJSONObject:files options:0 error:nil];
                    sendLE(cli, json3 ? json3.bytes : NULL, json3 ? json3.length : 0);
                } else if (strncmp(line, "delete ", 7) == 0 && line[7]) {
                    NSString *rel = @(line + 7);
                    BOOL okd = NO;
                    if (![rel containsString:@".."]) {
                        okd = [[NSFileManager defaultManager] removeItemAtPath:[MatisuScriptDir() stringByAppendingPathComponent:rel] error:nil];
                    }
                    const char *resp = okd ? "OK\n" : "FAIL\n";
                    sendLE(cli, resp, strlen(resp));
                } else if (strncmp(line, "start ", 6) == 0 && line[6]) {
                    // start <b64(lua)>：常驻脚本（后台线程，print 进共享缓冲）
                    NSData *src = [[NSData alloc] initWithBase64EncodedString:@(line + 6) options:0];
                    NSString *code = src ? [[NSString alloc] initWithData:src encoding:NSUTF8StringEncoding] : nil;
                    BOOL oks = code && MatisuLuaStart(code);
                    const char *resp = oks ? "OK\n" : "FAIL\n";
                    sendLE(cli, resp, strlen(resp));
                } else if (strcmp(line, "stop") == 0) {
                    MatisuLuaStop();
                    sendOK(cli);
                } else if (strcmp(line, "state") == 0) {
                    // state：常驻脚本状态 + 累计输出（取走即清）
                    NSDictionary *r = @{ @"running": @(MatisuLuaRunning()), @"output": MatisuLuaDrainOutput() };
                    NSData *json4 = [NSJSONSerialization dataWithJSONObject:r options:0 error:nil];
                    sendLE(cli, json4 ? json4.bytes : NULL, json4 ? json4.length : 0);
                } else if (strncmp(line, "getpixel ", 9) == 0) {
                    // getpixel <x> <y> -> BBGGRR hex（抓抓取色用，逻辑点坐标）
                    int gx, gy;
                    int gc = -1;
                    if (sscanf(line + 9, "%d %d", &gx, &gy) == 2) gc = MatisuCapturePixel(gx, gy);
                    char gresp[16];
                    int grl = gc >= 0 ? snprintf(gresp, sizeof(gresp), "%06X\n", (unsigned)gc & 0xFFFFFF)
                                      : snprintf(gresp, sizeof(gresp), "-1\n");
                    sendLE(cli, gresp, (size_t)grl);
                } else if (strncmp(line, "findcolor ", 10) == 0) {
                    // findcolor x1 y1 x2 y2 <color> <dir> <sim> -> "x y\n"（未中 -1 -1）
                    int x1, y1, x2, y2, dir; double simv; char color[128];
                    int ox = -1, oy = -1;
                    if (sscanf(line + 10, "%d %d %d %d %127s %d %lf", &x1, &y1, &x2, &y2, color, &dir, &simv) == 7) {
                        MatisuFindColor(x1, y1, x2, y2, @(color), dir, simv, &ox, &oy);
                    }
                    char resp[32];
                    int rl = snprintf(resp, sizeof(resp), "%d %d\n", ox, oy);
                    sendLE(cli, resp, (size_t)rl);
                } else if (strncmp(line, "cmpcolor ", 9) == 0) {
                    // cmpcolor x y <color> <sim> -> "1\n"/"0\n"
                    int x, y; double simv; char color[128];
                    int r = 0;
                    if (sscanf(line + 9, "%d %d %127s %lf", &x, &y, color, &simv) == 4) {
                        r = MatisuCmpColor(x, y, @(color), simv);
                    }
                    char resp[8];
                    int rl = snprintf(resp, sizeof(resp), "%d\n", r);
                    sendLE(cli, resp, (size_t)rl);
                } else if (strncmp(line, "cmpcolorex ", 11) == 0) {
                    // cmpcolorex <multi 串> <sim>（multi 无空格：x|y|color,...）
                    char multi[1024]; double simv;
                    int r = 0;
                    if (sscanf(line + 11, "%1023s %lf", multi, &simv) == 2) {
                        r = MatisuCmpColorEx(@(multi), simv);
                    }
                    char resp[8];
                    int rl = snprintf(resp, sizeof(resp), "%d\n", r);
                    sendLE(cli, resp, (size_t)rl);
                } else if (strncmp(line, "getcolornum ", 12) == 0) {
                    // getcolornum x1 y1 x2 y2 <color> <sim> -> "n\n"
                    int x1, y1, x2, y2; double simv; char color[128];
                    int n = 0;
                    if (sscanf(line + 12, "%d %d %d %d %127s %lf", &x1, &y1, &x2, &y2, color, &simv) == 6) {
                        n = MatisuGetColorNum(x1, y1, x2, y2, @(color), simv);
                    }
                    char resp[16];
                    int rl = snprintf(resp, sizeof(resp), "%d\n", n);
                    sendLE(cli, resp, (size_t)rl);
                } else if (strcmp(line, "getclipboard") == 0) {
                    NSString *cb = MatisuReadPasteboard();
                    NSData *d = [cb dataUsingEncoding:NSUTF8StringEncoding];
                    sendLE(cli, d.bytes, d.length);
                } else if (strncmp(line, "setclipboard ", 13) == 0 && line[13]) {
                    NSData *d = [[NSData alloc] initWithBase64EncodedString:@(line + 13) options:0];
                    NSString *t = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"";
                    MatisuWritePasteboard(t ?: @"");
                    sendOK(cli);
                } else if (strncmp(line, "openapp ", 8) == 0 && line[8]) {
                    BOOL ok = MatisuOpenApp(@(line + 8));
                    const char *resp = ok ? "OK\n" : "FAIL\n";
                    sendLE(cli, resp, strlen(resp));
                } else if (strncmp(line, "openurl ", 8) == 0 && line[8]) {
                    NSData *d = [[NSData alloc] initWithBase64EncodedString:@(line + 8) options:0];
                    NSString *u = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
                    BOOL ok = u && MatisuOpenURL(u);
                    const char *resp = ok ? "OK\n" : "FAIL\n";
                    sendLE(cli, resp, strlen(resp));
                } else if (strcmp(line, "frontapp") == 0) {
                    NSData *d = queryTweak("frontapp", 3.0);    // 优先 SpringBoard tweak（全系统可见）
                    if (!d) {
                        NSString *fa = MatisuFrontApp() ?: @"";
                        d = [fa dataUsingEncoding:NSUTF8StringEncoding];
                    }
                    sendLE(cli, d.bytes, d.length);
                } else if (strcmp(line, "diag") == 0) {
                    NSDictionary *d = @{
                        @"ax": MatisuAXDiag() ?: @{},
                        @"screen": MatisuScreenDiag() ?: @{},
                        @"frontapp": MatisuFrontAppDiag() ?: @{},
                    };
                    NSData *json = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
                    if (json && json.length) sendLE(cli, json.bytes, json.length);
                    else sendLE(cli, NULL, 0);
                } else if (strcmp(line, "devinfo") == 0) {
                    NSData *json = MatisuDeviceInfoJSON();
                    if (json && json.length) {
                        sendLE(cli, json.bytes, json.length);
                    } else {
                        sendLE(cli, NULL, 0);
                        NSLog(@"[MatisuAuto] devinfo failed");
                    }
                } else {
                    NSLog(@"[MatisuAuto] unknown cmd: %s", line);
                    sendOK(cli);
                }
                free(line);
            }
        }
    } // @autoreleasepool
    close(cli);
    return NULL;
}

static void* MAServerLoop(void* arg) {
    (void)arg;
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) { perror("socket"); return NULL; }
    int opt = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(18182);
    addr.sin_addr.s_addr = INADDR_ANY;

    if (bind(srv, (struct sockaddr*)&addr, sizeof(addr)) < 0) { perror("bind"); close(srv); return NULL; }
    if (listen(srv, 4) < 0) { perror("listen"); close(srv); return NULL; }

    NSLog(@"[MatisuAuto] control server listening on :18182");

    while (1) {
        int cli = accept(srv, NULL, NULL);
        if (cli < 0) continue;
        pthread_t ctid;
        if (pthread_create(&ctid, NULL, MAClientLoop, (void *)(intptr_t)cli) == 0) {
            pthread_detach(ctid);
        } else {
            close(cli);
        }
    }
    return NULL;
}

void MatisuControlServerStart(void) {
    // 脚本相对路径基准：io.open("资源/x.png") / require 等相对路径统一相对 run/ 解析（对齐原版语义）
    chdir(MatisuRunDir().fileSystemRepresentation);
    // 触控坐标归一化基准：digitizer HID 事件用 0~1 归一化坐标，
    // 以当前屏幕逻辑点尺寸为基准（与 PC 端下发坐标系一致）
    CGSize pts = [UIScreen mainScreen].bounds.size;
    if (pts.width > 0 && pts.height > 0) {
        MatisuTouchSetScreenSize((float)pts.width, (float)pts.height);
    }
    NSLog(@"[MatisuAuto] touch normalize base: %.0fx%.0f", pts.width, pts.height);
    pthread_t tid;
    pthread_create(&tid, NULL, MAServerLoop, NULL);
    pthread_detach(tid);
}
