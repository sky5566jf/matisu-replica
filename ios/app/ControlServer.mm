#import "ControlServer.h"
#import "TouchInject.h"
#import "ScreenShot.h"
#import "AXNodeDump.h"
#import "DeviceInfo.h"
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
                    NSData *json = MatisuDumpNodesJSON();
                    if (json && json.length) {
                        sendLE(cli, json.bytes, json.length);
                        NSLog(@"[MatisuAuto] uinode -> %lu bytes", (unsigned long)json.length);
                    } else {
                        sendLE(cli, NULL, 0);
                        NSLog(@"[MatisuAuto] uinode failed (需 accessibility.inspection 授权)");
                    }
                } else if (strcmp(line, "frontapp") == 0) {
                    NSString *fa = MatisuFrontApp() ?: @"";
                    NSData *d = [fa dataUsingEncoding:NSUTF8StringEncoding];
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
