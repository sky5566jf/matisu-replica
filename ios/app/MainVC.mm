// MatisuAuto — 主界面实现（对标原版懒人精灵 iOS app 布局）
#import "MainVC.h"
#import "DeviceInfo.h"
#import "Watchdog.h"
#import "MatisuPaths.h"
#import "LuaEngine.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

#define MA_BG   [UIColor colorWithRed:0.955 green:0.96 blue:0.97 alpha:1]
#define MA_CARD [UIColor whiteColor]
#define MA_SUB  [UIColor colorWithWhite:0.45 alpha:1]

// ---------------- 本机 daemon socket（127.0.0.1:18182，文本指令/[4B len][payload]） ----------------
static NSData *maSock(NSString *cmd, double timeout) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    struct timeval tv = { (time_t)timeout, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(18182);
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { close(fd); return nil; }
    NSData *line = [[cmd stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    write(fd, line.bytes, line.length);
    uint8_t head[4];
    ssize_t got = recv(fd, head, 4, MSG_WAITALL);
    if (got != 4) { close(fd); return nil; }
    uint32_t n = (head[0] << 24) | (head[1] << 16) | (head[2] << 8) | head[3];
    NSMutableData *data = [NSMutableData dataWithCapacity:n];
    while (data.length < n) {
        uint8_t buf[16384];
        ssize_t r = recv(fd, buf, MIN((uint32_t)sizeof(buf), n - (uint32_t)data.length), 0);
        if (r <= 0) break;
        [data appendBytes:buf length:r];
    }
    close(fd);
    return data;
}

// ---------------- 通用小部件 ----------------
static UILabel *maLabel(NSString *text, UIFont *font, UIColor *color) {
    UILabel *l = [[UILabel alloc] init];
    l.text = text; l.font = font; l.textColor = color;
    return l;
}

static UIButton *maBtn(NSString *title, UIColor *bg) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.backgroundColor = bg;
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    b.layer.cornerRadius = 8;
    return b;
}

static UIView *maCard(UIView *parent, CGFloat y, CGFloat w, CGFloat h) {
    UIView *c = [[UIView alloc] initWithFrame:CGRectMake(16, y, w, h)];
    c.backgroundColor = MA_CARD;
    c.layer.cornerRadius = 12;
    [parent addSubview:c];
    return c;
}

static UILabel *maSectionTitle(UIView *parent, NSString *text, CGFloat y, CGFloat w) {
    UILabel *l = maLabel(text, [UIFont boldSystemFontOfSize:16], UIColor.labelColor);
    l.frame = CGRectMake(16, y, w, 22);
    [parent addSubview:l];
    return l;
}

static NSString *maFmtTime(id ts) {
    long long v = [ts longLongValue];
    if (v <= 0) return @"-";
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"MM-dd HH:mm:ss";
    return [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)v]];
}

static NSString *maAgo(id ts) {
    long long v = [ts longLongValue];
    if (v <= 0) return @"-";
    long long diff = (long long)[[NSDate date] timeIntervalSince1970] - v;
    if (diff < 5) return @"刚刚";
    if (diff < 60) return [NSString stringWithFormat:@"%lld 秒前", diff];
    if (diff < 3600) return [NSString stringWithFormat:@"%lld 分前", diff / 60];
    return [NSString stringWithFormat:@"%lld 小时前", diff / 3600];
}

// ================= 主界面 =================
@interface MainVC ()
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *wdLabel;
@property (nonatomic, strong) UISwitch *wdSwitch;
@end

@implementation MainVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"MatisuAuto";
    self.view.backgroundColor = MA_BG;

    NSDictionary *info = [NSJSONSerialization JSONObjectWithData:MatisuDeviceInfoJSON() options:0 error:nil] ?: @{};
    CGFloat W = [UIScreen mainScreen].bounds.size.width;
    CGFloat w = W - 32;

    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    sv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    sv.alwaysBounceVertical = YES;
    [self.view addSubview:sv];
    UIView *cv = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, 900)];
    [sv addSubview:cv];

    CGFloat y = 16;

    // ---- 设备信息卡 ----
    maSectionTitle(cv, @"设备信息", y, w);
    y += 30;
    UIView *card = maCard(cv, y, w, 132);
    NSArray *rows = @[
        @[@"设备名称:", info[@"modelName"] ?: @"-"],
        @[@"系统版本:", [NSString stringWithFormat:@"iOS %@", info[@"systemVersion"] ?: @"-"]],
        @[@"设备型号:", info[@"model"] ?: @"-"],
        @[@"屏幕尺寸:", [NSString stringWithFormat:@"%@x%@", info[@"width"] ?: @"?", info[@"height"] ?: @"?"]],
    ];
    for (int i = 0; i < 4; i++) {
        UILabel *k = maLabel(rows[i][0], [UIFont systemFontOfSize:14], MA_SUB);
        k.frame = CGRectMake(14, 10 + i * 30, 90, 22);
        UILabel *v = maLabel(rows[i][1], [UIFont systemFontOfSize:14], UIColor.labelColor);
        v.frame = CGRectMake(104, 10 + i * 30, w - 118, 22);
        [card addSubview:k]; [card addSubview:v];
    }
    y += 150;

    // ---- 服务控制（脚本启停） ----
    maSectionTitle(cv, @"脚本服务", y, w);
    y += 30;
    CGFloat bw = (w - 12) / 2;
    UIButton *start = maBtn(@"启动脚本", [UIColor systemGreenColor]);
    start.frame = CGRectMake(16, y, bw, 40);
    [start addTarget:self action:@selector(onStart) forControlEvents:UIControlEventTouchUpInside];
    UIButton *stop = maBtn(@"停止脚本", [UIColor systemRedColor]);
    stop.frame = CGRectMake(16 + bw + 12, y, bw, 40);
    [stop addTarget:self action:@selector(onStop) forControlEvents:UIControlEventTouchUpInside];
    [cv addSubview:start]; [cv addSubview:stop];
    y += 52;

    self.statusLabel = maLabel(@"状态: 未知", [UIFont systemFontOfSize:13], MA_SUB);
    self.statusLabel.frame = CGRectMake(16, y, w, 56);
    self.statusLabel.numberOfLines = 3;
    [cv addSubview:self.statusLabel];
    y += 64;

    // ---- 常驻保活（看门狗） ----
    maSectionTitle(cv, @"常驻保活", y, w);
    y += 30;
    UIView *wdCard = maCard(cv, y, w, 158);

    self.wdSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - 65, 12, 51, 31)];
    [self.wdSwitch addTarget:self action:@selector(onKeepAlive:) forControlEvents:UIControlEventValueChanged];
    [wdCard addSubview:self.wdSwitch];
    UILabel *k0 = maLabel(@"崩溃自动拉起", [UIFont systemFontOfSize:15], UIColor.labelColor);
    k0.frame = CGRectMake(14, 16, w - 90, 22);
    [wdCard addSubview:k0];

    self.wdLabel = maLabel(@"读取中…", [UIFont systemFontOfSize:12.5], MA_SUB);
    self.wdLabel.frame = CGRectMake(14, 44, w - 28, 76);
    self.wdLabel.numberOfLines = 5;
    [wdCard addSubview:self.wdLabel];

    UIButton *wake = maBtn(@"立即拉起守护", [UIColor systemIndigoColor]);
    wake.frame = CGRectMake(14, 116, w - 28, 32);
    wake.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [wake addTarget:self action:@selector(onWakeNow) forControlEvents:UIControlEventTouchUpInside];
    [wdCard addSubview:wake];
    y += 176;

    // ---- 文件浏览器 ----
    maSectionTitle(cv, @"文件浏览", y, w);
    y += 30;
    UIButton *logs = [self dirBtn:@"日志 / 看门狗日志" frame:CGRectMake(16, y, bw, 64)
                            color:[UIColor colorWithRed:0.35 green:0.45 blue:0.65 alpha:1]];
    [logs addTarget:self action:@selector(openLogs) forControlEvents:UIControlEventTouchUpInside];
    UIButton *work = [self dirBtn:@"脚本工作目录" frame:CGRectMake(16 + bw + 12, y, bw, 64)
                            color:[UIColor colorWithRed:0.5 green:0.4 blue:0.25 alpha:1]];
    [work addTarget:self action:@selector(openWork) forControlEvents:UIControlEventTouchUpInside];
    [cv addSubview:logs]; [cv addSubview:work];
    y += 80;

    sv.contentSize = CGSizeMake(W, y + 24);

    [self onRefresh];
    [self onRefreshWatchdog];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self onRefresh];
    [self onRefreshWatchdog];
}

- (UIButton *)dirBtn:(NSString *)title frame:(CGRect)frame color:(UIColor *)c {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    b.backgroundColor = c;
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.numberOfLines = 2;
    b.layer.cornerRadius = 10;
    b.frame = frame;
    return b;
}

#pragma mark - 脚本服务

- (void)onStart {
    NSString *src = MatisuEntryScriptSource();   // entry.json(lc_entry) 优先，退化 autorun.lua
    if (!src.length) { self.statusLabel.text = @"状态: 无入口脚本（先装脚本包或用 IDE 上传）"; return; }
    NSString *b64 = [[src dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    NSData *r = maSock([@"start " stringByAppendingString:b64], 5);
    NSString *resp = r ? [[NSString alloc] initWithData:r encoding:NSUTF8StringEncoding] : @"连接失败";
    self.statusLabel.text = [@"状态: " stringByAppendingString:[resp stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self onRefresh]; });
}

- (void)onStop {
    NSData *r = maSock(@"stop", 5);
    NSString *resp = r ? [[NSString alloc] initWithData:r encoding:NSUTF8StringEncoding] : @"连接失败";
    self.statusLabel.text = [@"状态: " stringByAppendingString:[resp stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self onRefresh]; });
}

- (void)onRefresh {
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSData *r = maSock(@"state", 5);
        NSString *text = @"状态: daemon 无响应";
        if (r) {
            NSDictionary *d = [NSJSONSerialization JSONObjectWithData:r options:0 error:nil];
            BOOL running = [d[@"running"] boolValue];
            NSString *out = [d[@"output"] description] ?: @"";
            if (out.length > 80) out = [@"…" stringByAppendingString:[out substringFromIndex:out.length - 80]];
            text = [NSString stringWithFormat:@"状态: %@%@", running ? @"🟢 运行中" : @"⚪ 空闲",
                    out.length ? [@"\n" stringByAppendingString:out] : @""];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ self.statusLabel.text = text; });
    });
}

#pragma mark - 常驻保活

- (void)onKeepAlive:(UISwitch *)s {
    if (s.on) MatisuWatchdogResume();
    else      MatisuWatchdogStop();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self onRefreshWatchdog]; });
}

- (void)onWakeNow {
    MatisuWatchdogResume();
    [self.wdSwitch setOn:YES animated:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self onRefreshWatchdog];
        [self onRefresh];
    });
}

- (void)onRefreshWatchdog {
    NSDictionary *d = MatisuWatchdogStatus();
    BOOL running = [d[@"running"] boolValue];
    BOOL stopped = [d[@"stopped"] boolValue];
    [self.wdSwitch setOn:!stopped animated:NO];

    NSString *head = running
        ? [NSString stringWithFormat:@"看门狗 🟢 运行中 (pid %@)", d[@"pid"] ?: @"?"]
        : @"看门狗 ⚪ 未运行";

    NSString *probe = [d[@"lastProbeOk"] boolValue]
        ? [NSString stringWithFormat:@"✅ 通 (%@)", maAgo(d[@"lastProbeAt"])]
        : [NSString stringWithFormat:@"❌ 不通 (%@)", maAgo(d[@"lastProbeAt"])];

    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"%@\n", head];
    [s appendFormat:@"守护进程: %@   探活: %@\n", [d[@"targetRunning"] intValue] ? @"在" : @"不在", probe];
    [s appendFormat:@"已拉起 %@ 次   上次: %@\n", d[@"restarts"] ?: @0, maFmtTime(d[@"lastRestartAt"])];
    [s appendFormat:@"连续失败 %@/%@   运行目录: %@",
        d[@"failStreak"] ?: @0, d[@"threshold"] ?: @3, d[@"runtimeDir"] ?: @"-"];
    self.wdLabel.text = s;
}

#pragma mark - 文件

- (void)openLogs {
    [self.navigationController pushViewController:
        [[FileListVC alloc] initWithDir:MatisuLogDir() title:@"日志目录"] animated:YES];
}
- (void)openWork {
    [self.navigationController pushViewController:
        [[FileListVC alloc] initWithDir:MatisuRunScriptsDir() title:@"工作目录"] animated:YES];
}
@end

// ================= 文件列表/查看 =================
@interface FileListVC () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *dir;
@property (nonatomic, strong) NSArray *files;
@end

@implementation FileListVC
- (instancetype)initWithDir:(NSString *)dir title:(NSString *)title {
    if ((self = [super init])) {
        _dir = [dir copy];
        self.title = title;
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = MA_BG;
    NSMutableArray *fs = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.dir error:nil] mutableCopy] ?: [NSMutableArray array];
    // 日志目录只列 .txt/.log（watchdog.log 走这条）
    if (![self.dir hasSuffix:@"scripts"]) {
        [fs filterUsingPredicate:[NSPredicate predicateWithFormat:@"self ENDSWITH '.txt' OR self ENDSWITH '.log'"]];
    }
    self.files = [fs sortedArrayUsingSelector:@selector(compare:)];
    UITableView *tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    tv.dataSource = self; tv.delegate = self;
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:tv];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.files.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    NSString *f = self.files[ip.row];
    c.textLabel.text = f;
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:[self.dir stringByAppendingPathComponent:f] error:nil];
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@ bytes", attr[NSFileSize] ?: @"?"];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *f = [self.dir stringByAppendingPathComponent:self.files[ip.row]];
    NSString *content = [NSString stringWithContentsOfFile:f encoding:NSUTF8StringEncoding error:nil] ?: @"(二进制/不可读)";
    UIViewController *vc = [[UIViewController alloc] init];
    vc.title = self.files[ip.row];
    UITextView *t = [[UITextView alloc] initWithFrame:vc.view.bounds];
    t.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    t.editable = NO;
    t.font = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont systemFontOfSize:12];
    if (content.length > 200000) content = [@"…（截断）\n" stringByAppendingString:[content substringFromIndex:content.length - 200000]];
    t.text = content;
    [vc.view addSubview:t];
    [self.navigationController pushViewController:vc animated:YES];
}
@end
