// MatisuAuto — 主界面实现（对标原版懒人精灵 iOS app 布局）
#import "MainVC.h"
#import "DeviceInfo.h"
#import "Watchdog.h"
#import "MatisuPaths.h"
#import <unistd.h>

#define MA_BG   [UIColor colorWithRed:0.955 green:0.96 blue:0.97 alpha:1]
#define MA_CARD [UIColor whiteColor]
#define MA_SUB  [UIColor colorWithWhite:0.45 alpha:1]

// ---------------- 通用小部件 ----------------
static UILabel *maLabel(NSString *text, UIFont *font, UIColor *color) {
    UILabel *l = [[UILabel alloc] init];
    l.text = text; l.font = font; l.textColor = color;
    return l;
}

static UIView *maCard(UIView *parent, CGFloat y, CGFloat w, CGFloat h) {
    UIView *c = [[UIView alloc] initWithFrame:CGRectMake(16, y, w, h)];
    c.backgroundColor = MA_CARD;
    c.layer.cornerRadius = 12;
    [parent addSubview:c];
    return c;
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

static UILabel *maSectionTitle(UIView *parent, NSString *text, CGFloat y, CGFloat w) {
    UILabel *l = maLabel(text, [UIFont boldSystemFontOfSize:16], UIColor.labelColor);
    l.frame = CGRectMake(16, y, w, 22);
    [parent addSubview:l];
    return l;
}

// ================= 主界面 =================
@interface MainVC ()
@property (nonatomic, strong) UILabel *svcLabel;
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
        @[@"设备名称:", info[@"name"] ?: @"-"],
        @[@"系统版本:", [NSString stringWithFormat:@"iOS %@", info[@"systemVersion"] ?: @"-"]],
        @[@"设备型号:", info[@"model"] ?: @"-"],
        @[@"屏幕尺寸:", [NSString stringWithFormat:@"%@x%@", info[@"pixelWidth"] ?: @"?", info[@"pixelHeight"] ?: @"?"]],
    ];
    for (int i = 0; i < 4; i++) {
        UILabel *k = maLabel(rows[i][0], [UIFont systemFontOfSize:14], MA_SUB);
        k.frame = CGRectMake(14, 10 + i * 30, 90, 22);
        UILabel *v = maLabel(rows[i][1], [UIFont systemFontOfSize:14], UIColor.labelColor);
        v.frame = CGRectMake(104, 10 + i * 30, w - 118, 22);
        [card addSubview:k]; [card addSubview:v];
    }
    y += 150;

    // ---- 服务控制（daemon + 看门狗总开关，对齐原版"启动服务/停止服务"） ----
    CGFloat bw = (w - 12) / 2;
    UIButton *svcStart = maBtn(@"启动服务", [UIColor systemGreenColor]);
    svcStart.frame = CGRectMake(16, y, bw, 40);
    [svcStart addTarget:self action:@selector(onSvcStart) forControlEvents:UIControlEventTouchUpInside];
    UIButton *svcStop = maBtn(@"停止服务", [UIColor systemRedColor]);
    svcStop.frame = CGRectMake(16 + bw + 12, y, bw, 40);
    [svcStop addTarget:self action:@selector(onSvcStop) forControlEvents:UIControlEventTouchUpInside];
    [cv addSubview:svcStart]; [cv addSubview:svcStop];
    y += 48;

    self.svcLabel = maLabel(@"服务状态: 读取中…", [UIFont systemFontOfSize:13], MA_SUB);
    self.svcLabel.frame = CGRectMake(16, y, w, 20);
    [cv addSubview:self.svcLabel];
    y += 30;

    // ---- 常驻保活：默认启动，不展示 ----
    // 后台线程：ServiceStart = EnsureStarted 看门狗 + 立即 spawnTarget 拉 daemon，
    // 打开 app 几秒内 :18182 就在；用 WatchdogResume 的话 daemon 要等 3 次探活
    // 失败（约 15s）才被拉起，状态行会误显示"已停止"。
    dispatch_async(dispatch_get_global_queue(0, 0), ^{ MatisuServiceStart(); });

    // ---- 文件浏览器 ----
    maSectionTitle(cv, @"文件浏览", y, w);
    y += 30;
    UIButton *logs = [self dirBtn:@"日志" frame:CGRectMake(16, y, bw, 64)
                            color:[UIColor colorWithRed:0.35 green:0.45 blue:0.65 alpha:1]];
    [logs addTarget:self action:@selector(openLogs) forControlEvents:UIControlEventTouchUpInside];
    UIButton *work = [self dirBtn:@"工作目录" frame:CGRectMake(16 + bw + 12, y, bw, 64)
                            color:[UIColor colorWithRed:0.5 green:0.4 blue:0.25 alpha:1]];
    [work addTarget:self action:@selector(openWork) forControlEvents:UIControlEventTouchUpInside];
    [cv addSubview:logs]; [cv addSubview:work];
    y += 80;

    sv.contentSize = CGSizeMake(W, y + 24);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshSvc];
}

#pragma mark - 服务控制

- (void)onSvcStart {
    self.svcLabel.text = @"服务状态: 启动中…";
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        MatisuServiceStart();
        // 等 daemon 把 :18182 拉起来再刷状态
        for (int i = 0; i < 20 && !MatisuPortInUse(18182); i++) usleep(250 * 1000);
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshSvc]; });
    });
}

- (void)onSvcStop {
    int killed = MatisuServiceStop();
    self.svcLabel.text = [NSString stringWithFormat:@"服务状态: ⚪ 已停止（结束 %d 个进程）", killed];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self refreshSvc]; });
}

- (void)refreshSvc {
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        BOOL up = MatisuPortInUse(18182);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.svcLabel.text = up ? @"服务状态: 🟢 运行中" : @"服务状态: ⚪ 已停止";
        });
    });
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

#pragma mark - 文件

- (void)openLogs {
    [self.navigationController pushViewController:
        [[FileListVC alloc] initWithDir:MatisuLogDir() title:@"日志"] animated:YES];
}
- (void)openWork {
    [self.navigationController pushViewController:
        [[FileListVC alloc] initWithDir:MatisuRunScriptsDir() title:@"工作目录"] animated:YES];
}
@end

// ================= 文件列表/查看 =================
@interface FileListVC () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *dir;
@property (nonatomic, strong) NSArray<NSString *> *files;      // 展示名
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *fullPaths;  // 展示名 -> 完整路径
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
    // 日志目录只列 .txt/.log；工作目录（run/脚本）全量列出
    if (![self.dir hasSuffix:@"scripts"] && ![self.dir hasSuffix:@"脚本"]) {
        [fs filterUsingPredicate:[NSPredicate predicateWithFormat:@"self ENDSWITH '.txt' OR self ENDSWITH '.log'"]];
    }
    self.fullPaths = [NSMutableDictionary dictionary];
    for (NSString *f in fs) self.fullPaths[f] = [self.dir stringByAppendingPathComponent:f];
    // 看门狗日志在数据区根目录，并入日志目录一起展示
    if ([self.dir isEqualToString:MatisuLogDir()]) {
        NSString *wd = [MatisuDataRoot() stringByAppendingPathComponent:@"watchdog.log"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:wd]) {
            [fs addObject:@"watchdog.log"];
            self.fullPaths[@"watchdog.log"] = wd;
        }
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
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:self.fullPaths[f] error:nil];
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@ bytes", attr[NSFileSize] ?: @"?"];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *f = self.fullPaths[self.files[ip.row]];
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
