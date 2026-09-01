// PackageManager.m — 极简 ZIP 读取（stored + deflate，zlib raw inflate）+ 包安装
#import "PackageManager.h"
#import "MatisuPaths.h"
#import <zlib.h>

#pragma mark - ZIP 读取

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }

/// 文件名安全校验：拒绝绝对路径、.. 穿越、空名
static BOOL maSafeName(NSString *name) {
    if (!name.length) return NO;
    if ([name hasPrefix:@"/"] || [name hasPrefix:@"\\"]) return NO;
    if ([name containsString:@".."]) return NO;
    if ([name rangeOfString:@":"].location != NSNotFound) return NO;   // 防 Windows 盘符/ADS
    return YES;
}

static NSData *maInflate(const uint8_t *src, NSUInteger srcLen, NSUInteger dstLen) {
    NSMutableData *out = [NSMutableData dataWithLength:dstLen];
    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    zs.next_in = (Bytef *)src;
    zs.avail_in = (uInt)srcLen;
    zs.next_out = out.mutableBytes;
    zs.avail_out = (uInt)dstLen;
    if (inflateInit2(&zs, -MAX_WBITS) != Z_OK) return nil;   // raw deflate（zip 无 zlib 头）
    int rc = inflate(&zs, Z_FINISH);
    inflateEnd(&zs);
    if (rc != Z_STREAM_END || zs.total_out != dstLen) return nil;
    return out;
}

int MatisuUnzipDataToDir(NSData *zipData, NSString *destDir) {
    const uint8_t *b = zipData.bytes;
    NSUInteger len = zipData.length;
    if (len < 22) return -1;

    // 找 EOCD（从尾部 64KB 内扫签名 0x06054b50）
    NSUInteger scanStart = len > 66000 ? len - 66000 : 0;
    NSInteger eocd = -1;
    for (NSInteger i = (NSInteger)len - 22; i >= (NSInteger)scanStart; i--) {
        if (rd32(b + i) == 0x06054b50) { eocd = i; break; }
    }
    if (eocd < 0) return -1;
    uint16_t entries = rd16(b + eocd + 10);
    uint32_t cdOff = rd32(b + eocd + 16);
    if ((uint64_t)cdOff >= len) return -1;

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];

    int written = 0;
    NSUInteger p = cdOff;
    for (uint16_t k = 0; k < entries; k++) {
        if (p + 46 > len || rd32(b + p) != 0x02014b50) return -1;
        uint16_t method   = rd16(b + p + 10);
        uint32_t compSz   = rd32(b + p + 20);
        uint32_t rawSz    = rd32(b + p + 24);
        uint16_t nameLen  = rd16(b + p + 28);
        uint16_t extraLen = rd16(b + p + 30);
        uint16_t cmtLen   = rd16(b + p + 32);
        uint32_t lho      = rd32(b + p + 42);
        if (p + 46 + nameLen > len) return -1;
        NSString *name = [[NSString alloc] initWithBytes:b + p + 46 length:nameLen encoding:NSUTF8StringEncoding];
        p += 46 + nameLen + extraLen + cmtLen;
        if (!name || !maSafeName(name)) continue;

        NSString *dst = [destDir stringByAppendingPathComponent:name];
        if ([name hasSuffix:@"/"]) {   // 目录条目
            [fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:nil];
            continue;
        }
        // 定位 local header，取数据区
        if ((uint64_t)lho + 30 > len || rd32(b + lho) != 0x04034b50) return -1;
        uint16_t lNameLen  = rd16(b + lho + 26);
        uint16_t lExtraLen = rd16(b + lho + 28);
        NSUInteger dataOff = lho + 30 + lNameLen + lExtraLen;
        if (dataOff + compSz > len) return -1;

        NSData *raw = nil;
        if (method == 0) {          // stored
            raw = [NSData dataWithBytes:b + dataOff length:compSz];
        } else if (method == 8) {   // deflate
            raw = maInflate(b + dataOff, compSz, rawSz);
        } else {
            continue;               // 不支持的方法（bzip2/aes 等），跳过而非整体失败
        }
        if (!raw) return -1;
        [fm createDirectoryAtPath:[dst stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        if (![raw writeToFile:dst atomically:YES]) return -1;
        written++;
    }
    return written;
}

#pragma mark - 包安装

BOOL MatisuInstallPackage(NSString *name, NSData *payload, int *outFiles, NSString **errMsg) {
    if (outFiles) *outFiles = 0;
    NSString *fail = ^NSString *(NSString *m) { if (errMsg) *errMsg = m; return m; };
    // 包名必须是纯文件名（无路径分隔符）
    if (!name.length || [name containsString:@"/"] || [name containsString:@"\\"] || [name containsString:@".."]) {
        fail(@"bad package name"); return NO;
    }
    if (!payload.length) { fail(@"empty payload"); return NO; }

    NSFileManager *fm = [NSFileManager defaultManager];

    // 1. 包原样落 script/
    NSString *pkgPath = [MatisuScriptPkgDir() stringByAppendingPathComponent:name];
    if (![payload writeToFile:pkgPath atomically:YES]) { fail(@"write package failed"); return NO; }

    // 2. 清空 run/（新包=整个工程替换，对齐原版语义）
    NSString *runDir = MatisuRunDir();
    for (NSString *item in [fm contentsOfDirectoryAtPath:runDir error:nil]) {
        [fm removeItemAtPath:[runDir stringByAppendingPathComponent:item] error:nil];
    }

    // 3. 解包进 run/
    int n = MatisuUnzipDataToDir(payload, runDir);
    if (n < 0) { fail(@"unzip failed (bad zip or truncated)"); return NO; }

    // 4. 资源/*.rc 二次解包到 资源/ 同级（rc 本身是 zip：res/x.png → 资源/res/x.png）
    NSString *resDir = MatisuRunResDir();
    for (NSString *item in [fm contentsOfDirectoryAtPath:resDir error:nil]) {
        if (![item.pathExtension.lowercaseString isEqualToString:@"rc"]) continue;
        NSString *rcPath = [resDir stringByAppendingPathComponent:item];
        NSData *rcData = [NSData dataWithContentsOfFile:rcPath];
        if (rcData.length) MatisuUnzipDataToDir(rcData, resDir);   // 失败不致命
    }

    if (outFiles) *outFiles = n;
    return YES;
}
