// MatisuAuto — 看门狗实现
//
// 状态机要点（对齐原版 RootWatchdog，并加注释说明取舍）：
//   1. 双 fork + setsid daemonize，孙进程 exec 自身 `--watchdog`，脱离 app 生命周期
//   2. flock 独占锁做 PID 锁 —— 进程崩溃时内核自动释放，比"读 pid + kill(pid,0)"可靠
//   3. 探活 = TCP connect 127.0.0.1:<port>，非阻塞 + select 控制超时
//   4. 启动期宽容：进程在但端口未起，只有超过 bootGrace 仍不通才判定僵死
//      （原版语义：进程在但端口没起来不算失败；这里补上"无限宽容"的兜底）
//   5. 延迟重启二次确认：决定重启后先睡 delay 秒再探一次，通了就放弃重启
//   6. 重启节流：两次重启间隔 < minInterval 则本轮跳过，避免打满 CPU 的崩溃循环
//   7. stopFlag 语义停止：存在时不拉起，区别于被 jetsam 杀掉
#import "Watchdog.h"
#import "MatisuPaths.h"

#import <sys/socket.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <sys/file.h>
#import <sys/wait.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <netinet/tcp.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <signal.h>
#import <stdarg.h>
#import <limits.h>
#import <time.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

#pragma mark - 小工具（纯 C，fork 后安全）

static void maWriteFileAtomic(const char *path, const char *data) {
    char tmp[PATH_MAX];
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    ssize_t want = (ssize_t)strlen(data);
    if (write(fd, data, want) != want) { /* 尽力而为 */ }
    close(fd);
    rename(tmp, path);
}

extern char **environ;   // exec 时沿用当前环境，避免 Foundation 因缺 HOME 走异常分支

static char *maReadFileCString(const char *path) {
    FILE *fp = fopen(path, "r");
    if (!fp) return NULL;
    static char buf[4096];
    size_t n = fread(buf, 1, sizeof(buf) - 1, fp);
    buf[n] = '\0';
    fclose(fp);
    return buf;
}

/// 目标进程是否存在（按可执行文件名匹配 kinfo_proc.comm）
/// excludePid：排除看门狗自身 —— 看门狗与目标同二进制同名，
/// 不排除会把"目标已死"误判成"目标在但端口未起"，白吃 bootGrace 90s 宽限。
static int maProcExists(const char *comm, pid_t excludePid) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) < 0) return -1;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(len);
    if (!procs) return -1;
    if (sysctl(mib, 4, procs, &len, NULL, 0) < 0) { free(procs); return -1; }
    int count = (int)(len / sizeof(struct kinfo_proc));
    int found = 0;
    for (int i = 0; i < count; i++) {
        if (procs[i].kp_proc.p_pid == excludePid) continue;
        if (strcmp(procs[i].kp_proc.p_comm, comm) == 0) { found = 1; break; }
    }
    free(procs);
    return found;
}

/// TCP 探活：能连上即认为服务可用
static int maProbePort(int port, int timeoutMs) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");

    int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (rc == 0) { close(fd); return 1; }
    if (errno != EINPROGRESS && errno != EAGAIN) { close(fd); return 0; }

    fd_set wf;
    FD_ZERO(&wf);
    FD_SET(fd, &wf);
    struct timeval tv = { timeoutMs / 1000, (timeoutMs % 1000) * 1000 };
    rc = select(fd + 1, NULL, &wf, NULL, &tv);
    if (rc > 0) {
        int err = 0;
        socklen_t elen = sizeof(err);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &elen) == 0 && err == 0) {
            close(fd);
            return 1;
        }
    }
    close(fd);
    return 0;
}

#pragma mark - 运行时目录 / 路径

/// 看门狗进程强制使用 app 传入的目录（exec 后 HOME 可能已被剥离，
/// 若各算各的会出现"app 写 A、看门狗读 B"的状态不一致）。
static NSString *gRuntimeOverride = nil;

/// 优先用数据区根目录（/var/mobile/Media/<bundle id>，PC 端与脚本都认这里）；
/// 沙箱场景（无共享写权限）回退到 app 的 Library 目录。
static NSString *maRuntimeDir(void) {
    static NSString *cached = nil;
    if (gRuntimeOverride) return gRuntimeOverride;
    if (cached) return cached;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *shared = MatisuDataRoot();
    if ([fm isWritableFileAtPath:shared]) {
        cached = shared;
    } else {
        NSString *alt = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/MatisuAuto"];
        [fm createDirectoryAtPath:alt withIntermediateDirectories:YES attributes:nil error:nil];
        cached = alt;
    }
    return cached;
}

static NSString *maPidFile(void)    { return [maRuntimeDir() stringByAppendingPathComponent:@".watchdog.pid"]; }
static NSString *maStopFile(void)   { return [maRuntimeDir() stringByAppendingPathComponent:@".watchdog.stop"]; }
static NSString *maStatusFile(void) { return [maRuntimeDir() stringByAppendingPathComponent:@".watchdog.status"]; }
static NSString *maLogFile(void)    { return [maRuntimeDir() stringByAppendingPathComponent:@"watchdog.log"]; }

/// 锁是否已被别的进程持有（= 看门狗在跑）
static int maPidFileLocked(void) {
    const char *p = maPidFile().fileSystemRepresentation;
    int fd = open(p, O_RDWR | O_CREAT, 0644);
    if (fd < 0) return 0;
    int rc = flock(fd, LOCK_EX | LOCK_NB);
    if (rc == 0) { flock(fd, LOCK_UN); close(fd); return 0; }
    close(fd);
    return 1;
}

#pragma mark - 日志（仅看门狗进程内使用）

static FILE *gLogFp = NULL;

static void wlog(const char *fmt, ...) {
    if (!gLogFp) return;
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    char ts[32];
    strftime(ts, sizeof(ts), "%m-%d %H:%M:%S", &tmv);
    fprintf(gLogFp, "[%s] ", ts);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(gLogFp, fmt, ap);
    va_end(ap);
    fputc('\n', gLogFp);
    fflush(gLogFp);
    long pos = ftell(gLogFp);
    if (pos > 512 * 1024) {   // 简单轮转：超 512KB 清空重写
        fclose(gLogFp);
        truncate(maLogFile().fileSystemRepresentation, 0);
        gLogFp = fopen(maLogFile().fileSystemRepresentation, "a");
    }
}

#pragma mark - 看门狗主体

typedef struct {
    char exe[PATH_MAX];
    char runtime[PATH_MAX];
    char comm[64];      // 进程名（basename(exe)，截断到 15）
    int  port;
    int  interval;      // 探活间隔（秒）
    int  threshold;     // 连续失败多少次才决定重启
    int  delay;         // 决定重启后的延迟（秒），期间做二次确认
    int  minInterval;   // 两次重启的最小间隔（秒），节流
    int  bootGrace;     // 进程在但端口未起的宽容期（秒）
    int  targetUid;     // >0 则拉起时降权到该 uid（原版 set_persona_np 降 root→mobile）
    int  headless;      // 1 = 拉起 --daemon 无头模式
} WatchdogConf;

static void writeStatus(const WatchdogConf *c, pid_t pid, time_t startedAt,
                        int restarts, time_t lastRestartAt, int lastProbeOk,
                        time_t lastProbeAt, int targetRunning, int failStreak) {
    char json[1024];
    snprintf(json, sizeof(json),
        "{\"pid\":%d,\"port\":%d,\"startedAt\":%lld,\"restarts\":%d,\"lastRestartAt\":%lld,"
        "\"lastProbeOk\":%d,\"lastProbeAt\":%lld,\"targetRunning\":%d,\"failStreak\":%d,"
        "\"interval\":%d,\"threshold\":%d,\"headless\":%d,\"stopped\":%d}",
        (int)pid, c->port, (long long)startedAt, restarts, (long long)lastRestartAt,
        lastProbeOk, (long long)lastProbeAt, targetRunning, failStreak,
        c->interval, c->threshold, c->headless,
        access(maStopFile().fileSystemRepresentation, F_OK) == 0 ? 1 : 0);
    maWriteFileAtomic(maStatusFile().fileSystemRepresentation, json);
}

/// fork + setsid + 二次 fork + execv，孙进程被 launchd 收养
static int spawnTarget(const WatchdogConf *c, pid_t *outPid) {
    pid_t p1 = fork();
    if (p1 < 0) return -1;
    if (p1 == 0) {
        setsid();
        signal(SIGHUP, SIG_IGN);
        pid_t p2 = fork();
        if (p2 < 0) _exit(127);
        if (p2 == 0) {
            chdir("/");
            int dn = open("/dev/null", O_RDWR);
            if (dn >= 0) {
                dup2(dn, STDIN_FILENO);
                dup2(dn, STDOUT_FILENO);
                dup2(dn, STDERR_FILENO);
                if (dn > STDERR_FILENO) close(dn);
            }
            signal(SIGPIPE, SIG_DFL);
            if (c->targetUid > 0) {
                setgid((gid_t)c->targetUid);
                setuid((uid_t)c->targetUid);
            }
            char *argv[6];
            argv[0] = (char *)c->exe;
            int ai = 1;
            if (c->headless) argv[ai++] = (char *)"--daemon";
            // 把运行时目录显式传给守护进程，否则它按自己的 HOME 另算一套，
            // 状态文件就会和 app / 看门狗看到的不一致
            argv[ai++] = (char *)"--runtime";
            argv[ai++] = (char *)c->runtime;
            argv[ai] = NULL;
            execve(c->exe, argv, environ);
            _exit(127);
        }
        _exit(0);
    }
    int st = 0;
    waitpid(p1, &st, 0);
    // 孙进程 pid 无法直接拿到，由调用方通过进程名查
    (void)outPid;
    return 0;
}

int MatisuWatchdogRun(int argc, char *argv[]) {
    @autoreleasepool {
        WatchdogConf c;
        memset(&c, 0, sizeof(c));
        // 默认值
        c.port = 18182;
        c.interval = 5;
        c.threshold = 3;
        c.delay = 3;
        c.minInterval = 10;
        c.bootGrace = 90;
        c.targetUid = 0;
        c.headless = 1;
        strncpy(c.comm, "MatisuAuto", sizeof(c.comm) - 1);

        // --watchdog <exe> <runtime> <port> [interval] [threshold] [delay] [minInterval] [uid] [headless]
        if (argc >= 4) {
            strncpy(c.exe, argv[2], sizeof(c.exe) - 1);
            strncpy(c.runtime, argv[3], sizeof(c.runtime) - 1);
        }
        if (argc >= 5) c.port = atoi(argv[4]);
        if (argc >= 6 && atoi(argv[5]) > 0) c.interval = atoi(argv[5]);
        if (argc >= 7 && atoi(argv[6]) > 0) c.threshold = atoi(argv[6]);
        if (argc >= 8 && atoi(argv[7]) > 0) c.delay = atoi(argv[7]);
        if (argc >= 9 && atoi(argv[8]) > 0) c.minInterval = atoi(argv[8]);
        if (argc >= 10) c.targetUid = atoi(argv[9]);
        if (argc >= 11) c.headless = atoi(argv[10]);
        if (c.exe[0] == '\0') return 2;

        // 关键：exec 之后 HOME 等环境变量可能与 app 不同，必须钉死 app 传来的目录
        if (c.runtime[0] != '\0') {
            gRuntimeOverride = [NSString stringWithUTF8String:c.runtime];
            [[NSFileManager defaultManager] createDirectoryAtPath:gRuntimeOverride
                                      withIntermediateDirectories:YES attributes:nil error:nil];
        }

        const char *base = strrchr(c.exe, '/');
        base = base ? base + 1 : c.exe;
        strncpy(c.comm, base, sizeof(c.comm) - 1);
        c.comm[15] = '\0';   // MAXCOMLEN+1

        // --- PID 锁（flock）：已有实例在跑则直接退出 ---
        const char *pidPath = maPidFile().fileSystemRepresentation;
        int lockFd = open(pidPath, O_RDWR | O_CREAT, 0644);
        if (lockFd < 0) return 3;
        if (flock(lockFd, LOCK_EX | LOCK_NB) != 0) {
            close(lockFd);
            return 0;   // 已有一个看门狗
        }
        ftruncate(lockFd, 0);
        char pidbuf[32];
        int pn = snprintf(pidbuf, sizeof(pidbuf), "%d\n", (int)getpid());
        if (write(lockFd, pidbuf, (size_t)pn) < 0) { /* 忽略 */ }

        // --- 打开日志 ---
        gLogFp = fopen(maLogFile().fileSystemRepresentation, "a");
        signal(SIGCHLD, SIG_IGN);    // 自动回收被拉起的子进程

        pid_t self = getpid();
        time_t startedAt = time(NULL);
        wlog("=== watchdog start pid=%d uid=%d port=%d interval=%ds threshold=%d headless=%d comm=%s exec=%s",
             (int)self, (int)getuid(), c.port, c.interval, c.threshold, c.headless, c.comm, c.exe);

        int restarts = 0;
        time_t lastRestartAt = 0;
        int lastProbeOk = 0;
        time_t lastProbeAt = 0;
        int failStreak = 0;
        time_t bootWaitSince = 0;     // 首次观察到"进程在但端口不通"的时刻

        while (1) {
            // 每轮一个 autoreleasepool：maPidFile()/maStopFile() 都返回 autorelease 的
            // NSString，外层 pool 永不结束，不套一层会稳定泄漏
            @autoreleasepool {
            // ---------- 1. 语义停止：不拉起，但仍周期性记录状态 ----------
            int stopped = (access(maStopFile().fileSystemRepresentation, F_OK) == 0);

            // ---------- 2. 探活 ----------
            lastProbeOk = maProbePort(c.port, 1500);
            lastProbeAt = time(NULL);
            int targetRunning = maProcExists(c.comm, self);

            if (lastProbeOk) {
                if (failStreak) wlog("probe ok after %d failures", failStreak);
                failStreak = 0;
                bootWaitSince = 0;
            } else {
                if (targetRunning == 1 && bootWaitSince == 0) {
                    bootWaitSince = lastProbeAt;
                    wlog("target up but port %d not accepting (startup grace %ds)", c.port, c.bootGrace);
                }
                if (stopped) {
                    // 主动停止：保持沉默
                    if (failStreak) { failStreak = 0; wlog("stopped by flag, not relaunching"); }
                } else {
                    // 启动期宽容：进程在、端口未起、且在宽限期内 -> 不计失败
                    int inGrace = (targetRunning == 1 && bootWaitSince > 0 &&
                                   (lastProbeAt - bootWaitSince) < c.bootGrace);
                    if (inGrace) {
                        // 不累加 failStreak
                    } else {
                        failStreak++;
                        wlog("probe FAIL #%d (target=%d graceExpired=%d)",
                             failStreak, targetRunning, targetRunning == 1 ? 1 : 0);
                    }
                }
            }

            writeStatus(&c, self, startedAt, restarts, lastRestartAt,
                        lastProbeOk, lastProbeAt, targetRunning, failStreak);

            // ---------- 3. 决定是否重启 ----------
            if (!stopped && failStreak >= c.threshold) {
                time_t now = time(NULL);
                long sinceLast = lastRestartAt ? (long)(now - lastRestartAt) : 9999;

                // 节流：距上次重启太近则本轮跳过（细节⑥）
                if (lastRestartAt && sinceLast < c.minInterval) {
                    wlog("restart throttled (%lds < %ds), wait", sinceLast, c.minInterval);
                } else {
                    // 延迟 + 二次确认（细节⑤）
                    sleep((unsigned)c.delay);
                    if (maProbePort(c.port, 1500)) {
                        wlog("recovered during delay, abandon restart");
                        failStreak = 0;
                        bootWaitSince = 0;
                    } else {
                        // 目标还在但端口不通且已过宽限期 -> 先杀后拉
                        if (maProcExists(c.comm, self) == 1) {
                            wlog("target alive but dead-locked, SIGKILL");
                            // 按名杀：遍历一次拿 pid
                            int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
                            size_t len = 0;
                            if (sysctl(mib, 4, NULL, &len, NULL, 0) == 0) {
                                struct kinfo_proc *ps = (struct kinfo_proc *)malloc(len);
                                if (ps && sysctl(mib, 4, ps, &len, NULL, 0) == 0) {
                                    int n = (int)(len / sizeof(struct kinfo_proc));
                                    for (int i = 0; i < n; i++) {
                                        if (strcmp(ps[i].kp_proc.p_comm, c.comm) == 0 &&
                                            ps[i].kp_proc.p_pid != self) {
                                            kill(ps[i].kp_proc.p_pid, SIGKILL);
                                            wlog("killed pid %d", ps[i].kp_proc.p_pid);
                                        }
                                    }
                                }
                                free(ps);
                            }
                            usleep(800 * 1000);
                        }
                        if (spawnTarget(&c, NULL) == 0) {
                            restarts++;
                            lastRestartAt = time(NULL);
                            failStreak = 0;
                            bootWaitSince = 0;
                            wlog("relaunched (restart #%d, uid=%d, headless=%d)", restarts, c.targetUid, c.headless);
                        } else {
                            wlog("spawn FAILED errno=%d", errno);
                        }
                    }
                }
            }
            }   // @autoreleasepool

            // ---------- 4. 心跳 ----------
            sleep((unsigned)(c.interval > 0 ? c.interval : 5));
        }
    }
    return 0;
}

#pragma mark - app 侧接口

static NSString *maExecutablePath(void) {
    static NSString *cached = nil;
    if (cached) return cached;
    cached = [[NSBundle mainBundle] executablePath] ?: @"";
    return cached;
}

void MatisuWatchdogEnsureStarted(void) {
    if (maPidFileLocked()) return;             // 已在跑
    NSString *exe = maExecutablePath();
    if (!exe.length) return;

    NSString *dir = maRuntimeDir();

    // fork 之后子进程只能调用 async-signal-safe 的函数，ObjC 的 autorelease 不在其列。
    // 所以先把所有参数固化成 C 字符串，子进程里一行 ObjC 都不碰。
    char exeC[PATH_MAX], dirC[PATH_MAX];
    strncpy(exeC, exe.fileSystemRepresentation, sizeof(exeC) - 1);
    exeC[sizeof(exeC) - 1] = '\0';
    strncpy(dirC, dir.fileSystemRepresentation, sizeof(dirC) - 1);
    dirC[sizeof(dirC) - 1] = '\0';
    char portC[16];  snprintf(portC, sizeof(portC), "%d", 18182);
    char ivC[8], thC[8], dlC[8], miC[8], uidC[8], hlC[8];
    snprintf(ivC, sizeof(ivC), "5");
    snprintf(thC, sizeof(thC), "3");
    snprintf(dlC, sizeof(dlC), "3");
    snprintf(miC, sizeof(miC), "10");
    // 以当前 uid 拉起主 app，与 TrollStore/rootless 下 mobile 部署一致；
    // 原版是从 root 降权到 mobile，我们本身就在 mobile，不能 setuid(0)。
    snprintf(uidC, sizeof(uidC), "%d", (int)getuid());
    snprintf(hlC, sizeof(hlC), "1");

    pid_t p1 = fork();
    if (p1 < 0) return;
    if (p1 == 0) {
        setsid();
        signal(SIGHUP, SIG_IGN);
        pid_t p2 = fork();
        if (p2 < 0) _exit(127);
        if (p2 == 0) {
            chdir("/");
            int dn = open("/dev/null", O_RDWR);
            if (dn >= 0) {
                dup2(dn, STDIN_FILENO);
                dup2(dn, STDOUT_FILENO);
                dup2(dn, STDERR_FILENO);
                if (dn > STDERR_FILENO) close(dn);
            }
            signal(SIGPIPE, SIG_DFL);
            char *argv[12];
            argv[0] = exeC;
            argv[1] = (char *)"--watchdog";
            argv[2] = exeC;
            argv[3] = dirC;
            argv[4] = portC;
            argv[5] = ivC;
            argv[6] = thC;
            argv[7] = dlC;
            argv[8] = miC;
            argv[9] = uidC;
            argv[10] = hlC;
            argv[11] = NULL;
            execve(exeC, argv, environ);
            _exit(127);
        }
        _exit(0);
    }
    int st = 0;
    waitpid(p1, &st, 0);
}

void MatisuWatchdogStop(void) {
    maWriteFileAtomic(maStopFile().fileSystemRepresentation, "1");
}

void MatisuWatchdogResume(void) {
    unlink(maStopFile().fileSystemRepresentation);
    MatisuWatchdogEnsureStarted();
}

BOOL MatisuWatchdogIsStopped(void) {
    return access(maStopFile().fileSystemRepresentation, F_OK) == 0;
}

void MatisuWatchdogKill(void) {
    char *s = maReadFileCString(maPidFile().fileSystemRepresentation);
    if (!s) return;
    int pid = atoi(s);
    if (pid > 1) kill((pid_t)pid, SIGTERM);
}

BOOL MatisuPortInUse(int port) {
    return maProbePort(port, 800) ? YES : NO;
}

void MatisuSetRuntimeDir(const char *dir) {
    if (!dir || !*dir) return;
    gRuntimeOverride = [NSString stringWithUTF8String:dir];
    [[NSFileManager defaultManager] createDirectoryAtPath:gRuntimeOverride
                              withIntermediateDirectories:YES attributes:nil error:nil];
}

NSDictionary *MatisuWatchdogStatus(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"runtimeDir"] = maRuntimeDir();
    d[@"stopped"] = @(MatisuWatchdogIsStopped());

    NSData *data = [NSData dataWithContentsOfFile:maStatusFile()];
    NSDictionary *s = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if ([s isKindOfClass:[NSDictionary class]]) [d addEntriesFromDictionary:s];

    int running = maPidFileLocked();
    d[@"running"] = @(running);
    NSNumber *pid = d[@"pid"];
    if (!running) d[@"pid"] = @(0);
    else if (pid && [pid intValue] > 1 && kill((pid_t)[pid intValue], 0) != 0) {
        // status 文件里的 pid 已失效（异常退出未清理）
        d[@"running"] = @(0);
        d[@"pid"] = @(0);
    }
    return d;
}
