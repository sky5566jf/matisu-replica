#import "ControlServer.h"
#import "TouchInject.h"
#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <pthread.h>
#import <string.h>

// 简易文本协议（每行一条指令）：
//   tap x y
//   swipe x1 y1 x2 y2 [duration]
//   down finger x y
//   move finger x y
//   up finger x y
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
        char buf[512];
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
                } else if (sscanf(line, "swipe %f %f %f %f %f", &x, &y, &x2, &y2, &d) >= 4) {
                    MatisuTouchSwipe(x, y, x2, y2, d);
                    NSLog(@"[MatisuAuto] swipe");
                } else if (sscanf(line, "down %d %f %f", &f, &x, &y) == 3) {
                    MatisuTouchDown(f, x, y);
                } else if (sscanf(line, "move %d %f %f", &f, &x, &y) == 3) {
                    MatisuTouchMove(f, x, y);
                } else if (sscanf(line, "up %d %f %f", &f, &x, &y) == 3) {
                    MatisuTouchUp(f, x, y);
                } else {
                    NSLog(@"[MatisuAuto] unknown cmd: %s", line);
                }
                line = strtok(NULL, "\r\n");
            }
        }
        close(cli);
    }
    return NULL;
}

void MatisuControlServerStart(void) {
    pthread_t tid;
    pthread_create(&tid, NULL, MAServerLoop, NULL);
    pthread_detach(tid);
}
