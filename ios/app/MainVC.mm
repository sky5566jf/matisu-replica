// MatisuAuto — 主界面实现（对标原版懒人精灵 iOS app 布局）
#import "MainVC.h"
#import "DeviceInfo.h"
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

// ================= 主界面 =================
@interface MainVC ()
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIScrollView *scroll;
@end

@implementation MainVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"MatisuAuto";
    self.view.backgroundColor = MA_BG;

    NSDictionary *info = [NSJSONSerialization JSONObjectWithData:MatisuDeviceInfoJSON() options:0 error:nil] ?: @{};

    CGFloat y = 16, W = [UIScreen mainScreen].bounds.size.width - 32;

    // ---- 设备信息卡 ----
    UILabel *h1 = maLabel(@"设备信息", [UIFont boldSystemFontOfSize:16], UIColor.labelColor);
    h1.frame = CGRectMake(16, y, W, 22);
    [self.view addSubview:h1];
    y += 30;

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(16, y, W, 132)];
    card.backgroundColor = MA_CARD;
    card.layer.cornerRadius = 12;
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
        v.frame = CGRectMake(104, 10 + i * 30, W - 118, 22);
        [card addSubview:k]; [card addSubview:v];
    }
    [self.view addSubview:card];
    y += 150;

    // ---- 服务控制 ----
    UILabel *h2 = maLabel(@"服务控制", [UIFont boldSystemFontOfSize:16], UIColor.labelColor);
    h2.frame = CGRectMake(16, y, W, 22);
    [self.view addSubview:h2];
    y += 30;

    CGFloat bw = (W - 12) / 2;
    UIButton *start = maBtn(@"启动服务", [UIColor systemGreenColor]);
    start.frame = CGRectMake(16, y, bw, 40);
    [start addTarget:self action:@selector(onStart) forControlEvents:UIControlEventTouchUpInside];
    UIButton *stop = maBtn(@"停止服务", [UIColor systemRedColor]);
    stop.frame = CGRectMake(16 + bw + 12, y, bw, 40);
    [stop addTarget:self action:@selector(onStop) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:start]; [self.view addSubview:stop];
    y += 52;

    UIButton *refresh = maBtn(@"刷新状态", [UIColor systemBlueColor]);
    refresh.frame = CGRectMake(16 + (W - bw) / 2, y, bw, 40);
    [refresh addTarget:self action:@selector(onRefresh) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:refresh];
    y += 52;

    self.statusLabel = maLabel(@"状态: 未知", [UIFont systemFontOfSize:13], MA_SUB);
    self.statusLabel.frame = CGRectMake(16, y, W, 60);
    self.statusLabel.numberOfLines = 3;
    [self.view addSubview:self.statusLabel];
    y += 68;

    // ---- 文件浏览器 ----
    UILabel *h3 = maLabel(@"文件浏览器", [UIFont boldSystemFontOfSize:16], UIColor.labelColor);
    h3.frame = CGRectMake(16, y, W, 22);
    [self.view addSubview:h3];
    y += 30;

    UIButton *logs = [self dirBtn:@"📋 日志目录" frame:CGRectMake(16, y, bw, 64)
                            color:[UIColor colorWithRed:0.35 green:0.45 blue:0.65 alpha:1]];
    [logs addTarget:self action:@selector(openLogs) forControlEvents:UIControlEventTouchUpInside];
    UIButton *work = [self dirBtn:@"📁 工作目录" frame:CGRectMake(16 + bw + 12, y, bw, 64)
                            color:[UIColor colorWithRed:0.5 green:0.4 blue:0.25 alpha:1]];
    [work addTarget:self action:@selector(openWork) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:logs]; [self.view addSubview:work];

    [self onRefresh];
}

- (UIButton *)dirBtn:(NSString *)title frame:(CGRect)frame color:(UIColor *)c {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    b.backgroundColor = c;
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.layer.cornerRadius = 10;
    b.frame = frame;
    return b;
}

- (void)onStart {
    NSString *src = [NSString stringWithContentsOfFile:@"/var/mobile/MatisuAuto/scripts/autorun.lua"
                                              encoding:NSUTF8StringEncoding error:nil];
    if (!src.length) { self.statusLabel.text = @"状态: 无 autorun.lua（先用 IDE 上传脚本）"; return; }
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

- (void)openLogs {
    [self.navigationController pushViewController:
        [[FileListVC alloc] initWithDir:@"/var/mobile/MatisuAuto" title:@"日志目录"] animated:YES];
}
- (void)openWork {
    [self.navigationController pushViewController:
        [[FileListVC alloc] initWithDir:@"/var/mobile/MatisuAuto/scripts" title:@"工作目录"] animated:YES];
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
    // 日志目录只列 .txt/.log
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
