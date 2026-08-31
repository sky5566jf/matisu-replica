#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "../app/AXNodeDump.h"
#import "../app/DeviceInfo.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <pthread.h>
#import <string.h>

// ============================================================
// MatisuAuto SpringBoard tweak —— 节点树/前台App 服务
// ------------------------------------------------------------
// 背景：iOS 16 上普通进程调 AXRuntime C API 一律 -25211(APIDisabled)，
//       而 SpringBoard 进程自带 AX 特权（XXTouch 同款架构：注入 SpringBoard
//       后在进程内取前台 App 的无障碍树）。
// 形态：%ctor 起 127.0.0.1:18183 回环 TCP 服务（仅本机，不暴露局域网）。
//   指令（文本行，回帧 = 4字节大端长度 + 负载）：
//     uinode    -> 前台 App 节点树 JSON（AXNodeDump，Android 同构字段）
//     frontapp  -> 前台 App bundle id（FBProcessManager，SpringBoard 全可见）
//     ping      -> "pong"
// MatisuAuto daemon(:18182) 收到 uinode/frontapp 时优先转发到本服务。
// ============================================================

#define MA_TWEAK_PORT 18183

static void sendFrame(int cli, NSData *d) {
    NSUInteger len = d ? d.length : 0;
    uint8_t head[4] = {
        (uint8_t)((len >> 24) & 0xFF), (uint8_t)((len >> 16) & 0xFF),
        (uint8_t)((len >> 8) & 0xFF),  (uint8_t)(len & 0xFF),
    };
    if (write(cli, head, 4) != 4) return;
    if (len) write(cli, d.bytes, len);
}

static void* MATweakServer(void* arg) {
    (void)arg;
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) return NULL;
    int opt = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(MA_TWEAK_PORT);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);  // 仅回环

    if (bind(srv, (struct sockaddr*)&addr, sizeof(addr)) < 0) { close(srv); return NULL; }
    if (listen(srv, 4) < 0) { close(srv); return NULL; }
    NSLog(@"[MatisuAuto] tweak node server on 127.0.0.1:%d", MA_TWEAK_PORT);

    while (1) {
        int cli = accept(srv, NULL, NULL);
        if (cli < 0) continue;
        char buf[1024];
        ssize_t n = recv(cli, buf, sizeof(buf) - 1, 0);
        if (n > 0) {
            buf[n] = 0;
            if (strncmp(buf, "uinode", 6) == 0) {
                NSData *json = MatisuDumpNodesJSON();
                sendFrame(cli, json);
                NSLog(@"[MatisuAuto] tweak uinode -> %lu bytes", (unsigned long)(json ? json.length : 0));
            } else if (strncmp(buf, "frontapp", 8) == 0) {
                NSString *fa = MatisuFrontApp() ?: @"";
                sendFrame(cli, [fa dataUsingEncoding:NSUTF8StringEncoding]);
            } else if (strncmp(buf, "ping", 4) == 0) {
                sendFrame(cli, [@"pong" dataUsingEncoding:NSUTF8StringEncoding]);
            } else {
                sendFrame(cli, nil);
            }
        }
        close(cli);
    }
    return NULL;
}

%ctor {
    @autoreleasepool {
        NSLog(@"[MatisuAuto] tweak loaded into %@ (pid=%d)",
              [[NSBundle mainBundle] bundleIdentifier], getpid());
        // 只在 SpringBoard 里起服务（backboardd 等其余进程不加载逻辑）
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if ([bid isEqualToString:@"com.apple.springboard"]) {
            pthread_t tid;
            pthread_create(&tid, NULL, MATweakServer, NULL);
            pthread_detach(tid);
        }
    }
}
