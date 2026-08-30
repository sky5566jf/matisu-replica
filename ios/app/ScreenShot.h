#import <Foundation/Foundation.h>

/**
 MatisuAuto iOS 整屏截图
 -----------------------
 采用与 TrollVNC 同源的 IOSurface + CARenderServerRenderDisplay 私有 SPI 方案
 （iOS 13+ 可用，iOS 14-16 实测稳定），把当前屏幕内容拷入一块 IOSurface，
 再经 CoreGraphics 编码为 PNG 字节流回传 PC 端做图色匹配。

 注意：本文件为自写干净实现，仅依赖公开 IOSurface 框架 + 一个 weak_import 私有符号，
 不引入任何第三方/GPL 头文件。
 */
NSData* _Nullable MatisuCapturePNG(void);
