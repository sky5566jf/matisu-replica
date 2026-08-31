#import "ControlServer.h"
#import "TouchInject.h"
#import "ScreenShot.h"
#import "AXNodeDump.h"
#import "DeviceInfo.h"
#import "LuaEngine.h"
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
        char buf[4096];
        ssize_t n;
        // 每连接一个 autoreleasepool：screencap/uinode 在非主线程产生大量
        // autoreleased 对象（UIImage/PNG/JSON），无 pool 会累积泄漏直至
        // jetsam per-process-limit 杀进程（真机实证 10 连发即崩）。
        @autoreleasepool {
        while ((n = recv(cli, buf, sizeof(buf) - 1, 0)) > 0) {
            buf[n] = 0;
            char* line = strtok(buf, "\r\n");
            while (line) {
                float x, y, x2, y2, d = 0.2f;
                int f = 0;
                if (sscanf(line, "tap %f %f", &x, &y) == 2) {
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
                line = strtok(NULL, "\r\n");
            }
        }
        } // @autoreleasepool
        close(cli);
    }
    return NULL;
}

void MatisuControlServerStart(void) {
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
