// MatisuAuto — 设备端 OCR（PP-OCRv6 small，onnxruntime C API）
// 管线：截图区域 → det(DB 检测) → 文本框 crop → rec(CTC 识别) → 文本+坐标
// 模型：models/det.onnx + rec.onnx + dict.txt（首次调用懒加载）
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// OCR 结果项
@interface MAOcrItem : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic, assign) float score;
@property (nonatomic, assign) int x, y, w, h;   // 逻辑点坐标
@end

/// 对逻辑点区域 (x1,y1,x2,y2) 做 OCR，返回 MAOcrItem 数组（未加载模型/无帧返空）
NSArray<MAOcrItem*>* MatisuOcrRegion(int x1, int y1, int x2, int y2);

/// 模型是否就绪（det/rec/dict 三件齐）
BOOL MatisuOcrReady(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
