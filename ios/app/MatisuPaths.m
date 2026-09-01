// MatisuPaths.m — 数据区路径中心实现（懒创建，线程安全）
#import "MatisuPaths.h"

static NSString *maEnsure(NSString *path) {
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return path;
}

NSString *MatisuDataRoot(void) {
    static NSString *root = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"com.matisu.auto";
        root = [@"/var/mobile/Media" stringByAppendingPathComponent:bid];
        maEnsure(root);
    });
    return root;
}

// 子目录不缓存（root 已缓存，拼接开销可忽略），每次都确保存在——
// 用户从文件管理器误删子目录后下一次访问自动重建。
NSString *MatisuSysDir(void)        { return maEnsure([MatisuDataRoot() stringByAppendingPathComponent:@"sys"]); }
NSString *MatisuOcrDir(void)        { return maEnsure([MatisuDataRoot() stringByAppendingPathComponent:@"ocr"]); }
NSString *MatisuScriptPkgDir(void)  { return maEnsure([MatisuDataRoot() stringByAppendingPathComponent:@"script"]); }
NSString *MatisuRunDir(void)        { return maEnsure([MatisuDataRoot() stringByAppendingPathComponent:@"run"]); }
NSString *MatisuRunScriptsDir(void) { return maEnsure([MatisuRunDir() stringByAppendingPathComponent:@"脚本"]); }
NSString *MatisuRunUIDir(void)      { return maEnsure([MatisuRunDir() stringByAppendingPathComponent:@"界面"]); }
NSString *MatisuRunResDir(void)     { return maEnsure([MatisuRunDir() stringByAppendingPathComponent:@"资源"]); }
NSString *MatisuRunPluginDir(void)  { return maEnsure([MatisuRunDir() stringByAppendingPathComponent:@"插件"]); }
NSString *MatisuWorkDir(void)       { return maEnsure([MatisuDataRoot() stringByAppendingPathComponent:@"work"]); }
NSString *MatisuLogDir(void)        { return maEnsure([MatisuDataRoot() stringByAppendingPathComponent:@"logdir"]); }
NSString *MatisuPersistDir(void)    { return maEnsure([MatisuDataRoot() stringByAppendingPathComponent:@"syspersist"]); }
