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

/// 字节 -> 十进制 GB（与厂商标称一致，64GB 设备显示约 64GB 而非 60GiB）
static NSString *maGB(unsigned long long b) {
    if (b == 0) return @"-";
    double gb = (double)b / 1e9;
    return gb >= 100 ? [NSString stringWithFormat:@"%.0f GB", gb]
                     : [NSString stringWithFormat:@"%.1f GB", gb];
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
    UIView *card = maCard(cv, y, w, 196);
    NSString *ip = info[@"localIp"];
    unsigned long long stT = [info[@"storageTotal"] unsignedLongLongValue];
    unsigned long long stF = [info[@"storageFree"] unsignedLongLongValue];
    NSArray *rows = @[
        @[@"设备名称:", info[@"name"] ?: @"-"],
        @[@"系统版本:", [NSString stringWithFormat:@"iOS %@", info[@"systemVersion"] ?: @"-"]],
        @[@"设备型号:", info[@"modelFriendly"] ?: info[@"model"] ?: @"-"],
        @[@"屏幕尺寸:", [NSString stringWithFormat:@"%@x%@", info[@"pixelWidth"] ?: @"?", info[@"pixelHeight"] ?: @"?"]],
        @[@"本机 IP:",  ip.length ? ip : @"未连接"],
        @[@"存储容量:", [NSString stringWithFormat:@"%@ / %@", maGB(stF), maGB(stT)]],
    ];
    for (int i = 0; i < 6; i++) {
        UILabel *k = maLabel(rows[i][0], [UIFont systemFontOfSize:14], MA_SUB);
        k.frame = CGRectMake(14, 10 + i * 30, 90, 22);
        UILabel *v = maLabel(rows[i][1], [UIFont systemFontOfSize:14], UIColor.labelColor);
        v.frame = CGRectMake(104, 10 + i * 30, w - 118, 22);
        [card addSubview:k]; [card addSubview:v];
    }
    y += 214;

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

    // 覆盖 daemon 启动期：spawnTarget 后 :18182 监听约 1-2s 起来，期间
    // viewWillAppear 触发的 refreshSvc 探测会显示"已停止"且不会自动复查，
    // 排程连续 6 次（1+1.5+2.25+3.4+5+7.5 ≈ 20s 兜底）保证状态行跟上去。
    for (int i = 0; i < 6; i++) {
        CGFloat dt = 1.0 + i * 1.5;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dt * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self refreshSvc]; });
    }

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

/// 文件大小友好显示（B/KB/MB/GB）
static NSString *maSize(unsigned long long b) {
    if (b < 1024) return [NSString stringWithFormat:@"%llu B", b];
    double kb = (double)b / 1024.0;
    if (kb < 1024) return [NSString stringWithFormat:@"%.1f KB", kb];
    double mb = kb / 1024.0;
    if (mb < 1024) return [NSString stringWithFormat:@"%.1f MB", mb];
    return [NSString stringWithFormat:@"%.2f GB", mb / 1024.0];
}

@interface FileListVC () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *dir;
@property (nonatomic, strong) NSArray<NSString *> *files;                              // 展示名
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *fullPaths;  // 展示名 -> 完整路径
@property (nonatomic, strong) UITableView *tv;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIToolbar *toolbar;      // 批量模式底部工具条
@property (nonatomic, strong) UIBarButtonItem *batchItem;
@property (nonatomic, strong) UIBarButtonItem *delItem;
@property (nonatomic, strong) NSDateFormatter *df;
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
    self.df = [[NSDateFormatter alloc] init];
    self.df.dateFormat = @"yyyy-MM-dd HH:mm";

    // 右上角：刷新 + 批量
    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                            target:self action:@selector(onRefreshFiles)];
    self.batchItem = [[UIBarButtonItem alloc] initWithTitle:@"批量" style:UIBarButtonItemStylePlain
                                                     target:self action:@selector(onBatch:)];
    self.navigationItem.rightBarButtonItems = @[refresh, self.batchItem];

    self.tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tv.dataSource = self; self.tv.delegate = self;
    self.tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tv.allowsMultipleSelectionDuringEditing = YES;
    self.tv.tableFooterView = [[UIView alloc] init];
    [self.view addSubview:self.tv];

    // 长按单文件删除（批量编辑模式下交给多选勾选，不触发）
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
    lp.minimumPressDuration = 0.6;
    [self.tv addGestureRecognizer:lp];

    self.emptyLabel = maLabel(@"（空）", [UIFont systemFontOfSize:14], MA_SUB);
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.frame = CGRectMake(0, 120, self.view.bounds.size.width, 22);
    self.emptyLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.emptyLabel.hidden = YES;
    [self.view addSubview:self.emptyLabel];

    [self setupToolbar];
    [self loadFiles];
}

- (void)setupToolbar {
    self.toolbar = [[UIToolbar alloc] initWithFrame:CGRectZero];
    self.toolbar.hidden = YES;
    self.delItem = [[UIBarButtonItem alloc] initWithTitle:@"删除" style:UIBarButtonItemStylePlain
                                                   target:self action:@selector(onDeleteSelected)];
    self.delItem.tintColor = UIColor.systemRedColor;
    self.delItem.enabled = NO;
    UIBarButtonItem *selAll = [[UIBarButtonItem alloc] initWithTitle:@"全选" style:UIBarButtonItemStylePlain
                                                             target:self action:@selector(onSelectAll)];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                         target:nil action:nil];
    self.toolbar.items = @[self.delItem, flex, selAll];
    [self.view addSubview:self.toolbar];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // 最低部署版本 iOS 14，safeAreaInsets 必然可用
    CGFloat bottomInset = self.view.safeAreaInsets.bottom;
    CGFloat tbH = 44 + bottomInset;
    CGFloat H = self.view.bounds.size.height, W = self.view.bounds.size.width;
    self.toolbar.frame = CGRectMake(0, H - tbH, W, tbH);
    // 批量模式下让出工具条高度，否则最后一行被盖住
    self.tv.frame = CGRectMake(0, 0, W, self.toolbar.hidden ? H : H - tbH + bottomInset);
}

#pragma mark - 数据

- (void)loadFiles {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *fs = [[fm contentsOfDirectoryAtPath:self.dir error:nil] mutableCopy] ?: [NSMutableArray array];
    // 日志目录只列 .txt/.log；工作目录（run/脚本）全量列出
    if (![self.dir hasSuffix:@"scripts"] && ![self.dir hasSuffix:@"脚本"]) {
        [fs filterUsingPredicate:[NSPredicate predicateWithFormat:@"self ENDSWITH '.txt' OR self ENDSWITH '.log'"]];
    }
    self.fullPaths = [NSMutableDictionary dictionary];
    for (NSString *f in fs) self.fullPaths[f] = [self.dir stringByAppendingPathComponent:f];
    // 看门狗日志在数据区根目录，并入日志目录一起展示
    if ([self.dir isEqualToString:MatisuLogDir()]) {
        NSString *wd = [MatisuDataRoot() stringByAppendingPathComponent:@"watchdog.log"];
        if ([fm fileExistsAtPath:wd]) {
            [fs addObject:@"watchdog.log"];
            self.fullPaths[@"watchdog.log"] = wd;
        }
    }
    // 目录排前面，其余按名称排序
    [fs sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        BOOL da = [self isDirName:a], db = [self isDirName:b];
        if (da != db) return da ? NSOrderedAscending : NSOrderedDescending;
        return [a compare:b];
    }];
    self.files = fs;
    self.emptyLabel.hidden = fs.count > 0;
    [self.tv reloadData];
    [self updateDelTitle];
}

- (BOOL)isDirName:(NSString *)n {
    BOOL d = NO;
    [[NSFileManager defaultManager] fileExistsAtPath:self.fullPaths[n] isDirectory:&d];
    return d;
}

- (void)onRefreshFiles { [self loadFiles]; }

#pragma mark - 批量删除

- (void)onBatch:(UIBarButtonItem *)item {
    BOOL enter = !self.tv.isEditing;
    [self.tv setEditing:enter animated:YES];
    item.title = enter ? @"完成" : @"批量";
    item.style = enter ? UIBarButtonItemStyleDone : UIBarButtonItemStylePlain;
    self.toolbar.hidden = !enter;
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    if (!enter) [self loadFiles];
}

- (void)onSelectAll {
    NSInteger n = self.files.count;
    if (!n) return;
    BOOL allSelected = (self.tv.indexPathsForSelectedRows.count == (NSUInteger)n);
    for (NSInteger i = 0; i < n; i++) {
        NSIndexPath *ip = [NSIndexPath indexPathForRow:i inSection:0];
        if (allSelected) [self.tv deselectRowAtIndexPath:ip animated:NO];
        else             [self.tv selectRowAtIndexPath:ip animated:NO scrollPosition:UITableViewScrollPositionNone];
    }
    [self updateDelTitle];
}

- (void)updateDelTitle {
    NSUInteger n = self.tv.indexPathsForSelectedRows.count;
    self.delItem.enabled = n > 0;
    self.delItem.title = n ? [NSString stringWithFormat:@"删除 (%lu)", (unsigned long)n] : @"删除";
}

- (void)onDeleteSelected {
    NSArray *ips = self.tv.indexPathsForSelectedRows ?: @[];
    NSMutableArray *names = [NSMutableArray array];
    for (NSIndexPath *ip in ips) {
        if ((NSUInteger)ip.row < self.files.count) [names addObject:self.files[ip.row]];
    }
    [self confirmDelete:names];
}

/// 统一删除入口：二次确认 -> 删除 -> 刷新 -> 结果提示
- (void)confirmDelete:(NSArray<NSString *> *)names {
    if (!names.count) return;
    NSString *msg = names.count == 1
        ? [NSString stringWithFormat:@"确定删除「%@」？此操作不可恢复。", names[0]]
        : [NSString stringWithFormat:@"确定删除选中的 %lu 个文件？此操作不可恢复。", (unsigned long)names.count];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"删除文件"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    // 注意：本文件是 ObjC++（.mm），C++ 模式下 typeof 不可用，须写显式类型
    __weak FileListVC *ws = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [ws doDelete:names];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)doDelete:(NSArray<NSString *> *)names {
    NSFileManager *fm = [NSFileManager defaultManager];
    int ok = 0, fail = 0;
    for (NSString *n in names) {
        NSString *p = self.fullPaths[n];
        if (!p) continue;
        NSError *e = nil;
        if ([fm removeItemAtPath:p error:&e]) ok++;
        else { fail++; NSLog(@"[MatisuAuto] 删除失败 %@: %@", p, e); }
    }
    [self loadFiles];
    NSString *msg = fail ? [NSString stringWithFormat:@"成功 %d 个，失败 %d 个（可能被占用）", ok, fail]
                         : [NSString stringWithFormat:@"已删除 %d 个文件", ok];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"完成" message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (self.tv.isEditing) return;              // 批量模式下交给多选
    NSIndexPath *ip = [self.tv indexPathForRowAtPoint:[g locationInView:self.tv]];
    if (!ip) return;
    [self confirmDelete:@[self.files[ip.row]]];
}

#pragma mark - 表格

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.files.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    NSString *f = self.files[ip.row];
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:self.fullPaths[f] error:nil];
    BOOL isDir = [attr[NSFileType] isEqualToString:NSFileTypeDirectory];
    c.textLabel.text = f;
    c.textLabel.textColor = isDir ? UIColor.systemBlueColor : UIColor.labelColor;
    if (isDir) {
        c.detailTextLabel.text = @"文件夹";
    } else {
        NSString *ts = @"";
        NSDate *mtime = attr[NSFileModificationDate];
        if (mtime) ts = [@"  ·  " stringByAppendingString:[self.df stringFromDate:mtime]];
        c.detailTextLabel.text = [maSize([attr[NSFileSize] unsignedLongLongValue]) stringByAppendingString:ts];
    }
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (tv.isEditing) { [self updateDelTitle]; return; }   // 批量模式只勾选
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *name = self.files[ip.row];
    NSString *p = self.fullPaths[name];
    BOOL isDir = NO;
    [[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&isDir];
    if (isDir) {   // 目录：递归浏览
        [self.navigationController pushViewController:
            [[FileListVC alloc] initWithDir:p title:name] animated:YES];
        return;
    }
    NSString *content = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
    if (!content) content = [self hexPreview:p];
    if (content.length > 200000) {
        content = [@"…（截断）\n" stringByAppendingString:[content substringFromIndex:content.length - 200000]];
    }
    UIViewController *vc = [[UIViewController alloc] init];
    vc.title = name;
    UITextView *t = [[UITextView alloc] initWithFrame:vc.view.bounds];
    t.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    t.editable = NO;
    t.font = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont systemFontOfSize:12];
    t.text = content;
    [vc.view addSubview:t];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)tableView:(UITableView *)tv didDeselectRowAtIndexPath:(NSIndexPath *)ip {
    if (tv.isEditing) [self updateDelTitle];
}

/// 非 UTF-8 文件：给一段十六进制预览，避免只显示"不可读"
- (NSString *)hexPreview:(NSString *)path {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d.length) return @"(空文件)";
    NSUInteger n = MIN(d.length, 512);
    NSMutableString *s = [NSMutableString stringWithString:@"(非文本文件 · 十六进制预览)\n"];
    const uint8_t *b = (const uint8_t *)d.bytes;
    for (NSUInteger i = 0; i < n; i += 16) {
        NSMutableString *hex = [NSMutableString string], *asc = [NSMutableString string];
        for (NSUInteger j = i; j < MIN(i + 16, n); j++) {
            [hex appendFormat:@"%02X ", b[j]];
            [asc appendFormat:@"%c", (b[j] >= 32 && b[j] < 127) ? b[j] : '.'];
        }
        [s appendFormat:@"%08lX  %@ %@\n", (unsigned long)i, hex, asc];
    }
    if (d.length > n) [s appendFormat:@"\n…共 %lu 字节", (unsigned long)d.length];
    return s;
}

/// 左滑删除（与长按等价，符合系统习惯）；批量模式下禁用，统一走底部"删除选中"
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (tv.isEditing) return nil;
    NSString *name = self.files[ip.row];
    // 注意：本文件是 ObjC++（.mm），C++ 模式下 typeof 不可用，须写显式类型
    __weak FileListVC *ws = self;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                    title:@"删除"
                                                                  handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [ws confirmDelete:@[name]];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

/// 编辑模式下不允许行内删除（统一走工具条的"删除选中"）
- (UITableViewCellEditingStyle)tableView:(UITableView *)tv
           editingStyleForRowAtIndexPath:(NSIndexPath *)ip { return UITableViewCellEditingStyleNone; }
@end
