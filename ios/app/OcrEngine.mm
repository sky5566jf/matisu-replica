// MatisuAuto — OCR 引擎实现（PP-OCRv6 small / onnxruntime C API）
// 结构：det(DB) → 框 → rec(LightSVTR+CTC) → 文本。标准 PP-OCR 后处理。
#import "OcrEngine.h"
#import "ScreenShot.h"
#import "MatisuPaths.h"
#import <UIKit/UIKit.h>
#import <vector>
#import <string>
#import <algorithm>
#import <cmath>
#import <stdarg.h>

// onnxruntime C API（CI 里下载 ios static xcframework 提供头文件）
#include "onnxruntime_c_api.h"

@implementation MAOcrItem
@end

namespace {

struct OcrCtx {
    const OrtApi *api = nullptr;
    OrtEnv *env = nullptr;
    OrtSession *det = nullptr;
    OrtSession *rec = nullptr;
    std::vector<std::string> dict;
    bool ready = false;
};
OcrCtx g;

// OCR 诊断：所有失败分支必须留痕。真机实测 Dopamine/iOS16 上 log show 抓不到该进程 NSLog，
// 故同时写文件 <数据区>/logdir/ocr_debug.log（SSH 直接 cat 可读）。
static void ocrLog(const char *fmt, ...) {
    char buf[1024];
    va_list ap; va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    NSLog(@"[MatisuAuto][OCR] %s", buf);
    @autoreleasepool {
        NSString *line = [NSString stringWithFormat:@"[%f] %s\n",
                          [[NSDate date] timeIntervalSince1970], buf];
        NSString *path = [MatisuLogDir() stringByAppendingPathComponent:@"ocr_debug.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
}
static void ocrLogStatus(const OrtApi *api, const char *where, OrtStatus *st) {
    if (!st) return;
    const char *msg = api ? api->GetErrorMessage(st) : "?";
    ocrLog("%s FAILED: %s", where, msg ? msg : "?");
}

const int DET_SIDE = 960;      // det 输入边长（32 倍数）
const int REC_H = 48;          // rec 输入高
const float DET_THRESH = 0.3f;
const float DET_BOX_THRESH = 0.5f;
const float DET_UNCLIP = 1.6f;

std::string modelPath(const char *name) {
    // 模型随 app 分发，放 bundle 内 ocr/（数据区不再存模型）
    NSString *p2 = [[[NSBundle mainBundle] bundlePath] stringByAppendingFormat:@"/ocr/%s", name];
    return p2.UTF8String;
}

bool initEngine() {
    if (g.ready) return true;
    if (!g.api) g.api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (!g.api) { ocrLog("OrtGetApiBase returned null api"); return false; }
    if (!g.env) {
        OrtStatus *est = g.api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "matisu", &g.env);
        if (est != nullptr) { ocrLogStatus(g.api, "CreateEnv", est); g.api->ReleaseStatus(est); return false; }
    }
    OrtSessionOptions *opt = nullptr;
    g.api->CreateSessionOptions(&opt);
    g.api->SetIntraOpNumThreads(opt, 2);
    std::string detPath = modelPath("det.onnx");
    OrtStatus *st = g.api->CreateSession(g.env, detPath.c_str(), opt, &g.det);
    if (st) { ocrLogStatus(g.api, "CreateSession det", st); ocrLog("det path=%s", detPath.c_str()); g.api->ReleaseStatus(st); g.api->ReleaseSessionOptions(opt); return false; }
    std::string recPath = modelPath("rec.onnx");
    st = g.api->CreateSession(g.env, recPath.c_str(), opt, &g.rec);
    g.api->ReleaseSessionOptions(opt);
    if (st) { ocrLogStatus(g.api, "CreateSession rec", st); ocrLog("rec path=%s", recPath.c_str()); g.api->ReleaseStatus(st); return false; }
    // 字典
    std::string dictPath = modelPath("dict.txt");
    NSString *dictStr = [NSString stringWithContentsOfFile:@(dictPath.c_str())
                                                  encoding:NSUTF8StringEncoding error:nil];
    if (!dictStr) { ocrLog("dict load FAILED path=%s", dictPath.c_str()); return false; }
    for (NSString *line in [dictStr componentsSeparatedByString:@"\n"]) {
        if (line.length) g.dict.push_back(line.UTF8String);
    }
    g.ready = !g.dict.empty();
    ocrLog("init ok, dict=%zu entries", g.dict.size());
    return g.ready;
}

// 取 IOSurface 帧（RGBA 物理像素）
bool grabFrame(std::vector<uint8_t> &rgba, int &w, int &h) {
    NSData *png = MatisuCapturePNG();
    if (!png) return false;
    UIImage *img = [UIImage imageWithData:png];
    if (!img) return false;
    CGImageRef cg = img.CGImage;
    w = (int)CGImageGetWidth(cg);
    h = (int)CGImageGetHeight(cg);
    rgba.resize((size_t)w * h * 4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(rgba.data(), w, h, 8, (size_t)w * 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return true;
}

// ---------------- det 前/后处理 ----------------
struct DetBox { float x0, y0, x1, y1; float score; };

// 双线性 resize RGBA→目标尺寸，输出 CHW float 归一化
void preprocessDet(const std::vector<uint8_t> &rgba, int w, int h,
                   int dw, int dh, std::vector<float> &out) {
    static const float mean[3] = {0.485f, 0.456f, 0.406f};
    static const float std_[3] = {0.229f, 0.224f, 0.225f};
    out.resize((size_t)3 * dw * dh);
    for (int y = 0; y < dh; y++) {
        float sy = (float)y * h / dh;
        int y0 = (int)sy; float fy = sy - y0;
        int y1 = std::min(y0 + 1, h - 1);
        for (int x = 0; x < dw; x++) {
            float sx = (float)x * w / dw;
            int x0 = (int)sx; float fx = sx - x0;
            int x1 = std::min(x0 + 1, w - 1);
            for (int c = 0; c < 3; c++) {
                float p00 = rgba[((size_t)y0 * w + x0) * 4 + c];
                float p01 = rgba[((size_t)y0 * w + x1) * 4 + c];
                float p10 = rgba[((size_t)y1 * w + x0) * 4 + c];
                float p11 = rgba[((size_t)y1 * w + x1) * 4 + c];
                float v = (p00 * (1 - fx) + p01 * fx) * (1 - fy) + (p10 * (1 - fx) + p11 * fx) * fy;
                out[(size_t)c * dw * dh + (size_t)y * dw + x] = (v / 255.0f - mean[c]) / std_[c];
            }
        }
    }
}

// DB 后处理：概率图 → 连通域 → unclip 矩形（简化版，近 RapidOCR）
std::vector<DetBox> postprocessDet(const float *prob, int pw, int ph, int ow, int oh) {
    // 二值图
    std::vector<uint8_t> bin((size_t)pw * ph);
    for (size_t i = 0; i < bin.size(); i++) bin[i] = prob[i] > DET_THRESH ? 255 : 0;
    // 简单连通域（BFS，8 邻域）
    std::vector<int> label((size_t)pw * ph, 0);
    std::vector<DetBox> boxes;
    int cur = 0;
    std::vector<int> stack;
    for (int y = 0; y < ph; y++) {
        for (int x = 0; x < pw; x++) {
            size_t idx = (size_t)y * pw + x;
            if (!bin[idx] || label[idx]) continue;
            cur++;
            int minx = x, maxx = x, miny = y, maxy = y;
            float scoreSum = 0; int cnt = 0;
            stack.clear();
            stack.push_back((int)idx);
            label[idx] = cur;
            while (!stack.empty()) {
                int cur_idx = stack.back(); stack.pop_back();
                int cy = cur_idx / pw, cx = cur_idx % pw;
                minx = std::min(minx, cx); maxx = std::max(maxx, cx);
                miny = std::min(miny, cy); maxy = std::max(maxy, cy);
                scoreSum += prob[cur_idx]; cnt++;
                for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
                    int nx = cx + dx, ny = cy + dy;
                    if (nx < 0 || ny < 0 || nx >= pw || ny >= ph) continue;
                    size_t ni = (size_t)ny * pw + nx;
                    if (bin[ni] && !label[ni]) { label[ni] = cur; stack.push_back((int)ni); }
                }
            }
            if (cnt < 8) continue;   // 过滤噪点
            float avg = scoreSum / cnt;
            if (avg < DET_BOX_THRESH) continue;
            // unclip：外扩
            float bw = (float)(maxx - minx), bh = (float)(maxy - miny);
            float area = bw * bh;
            float dist = area * DET_UNCLIP / (2.0f * (bw + bh) + 1e-5f);
            DetBox b;
            b.x0 = std::max(0.0f, minx - dist); b.y0 = std::max(0.0f, miny - dist);
            b.x1 = std::min((float)pw, maxx + dist); b.y1 = std::min((float)ph, maxy + dist);
            b.score = avg;
            // 映射回原图坐标
            float kx = (float)ow / pw, ky = (float)oh / ph;
            b.x0 *= kx; b.x1 *= kx; b.y0 *= ky; b.y1 *= ky;
            boxes.push_back(b);
        }
    }
    // 按从上到下、从左到右排序
    std::sort(boxes.begin(), boxes.end(), [](const DetBox &a, const DetBox &b2) {
        if (fabsf(a.y0 - b2.y0) > 10) return a.y0 < b2.y0;
        return a.x0 < b2.x0;
    });
    return boxes;
}

// rec 前处理：crop 矩形 → 高 48 等比 resize → CHW float
void preprocessRec(const std::vector<uint8_t> &rgba, int w, int h, const DetBox &b,
                   std::vector<float> &out, int &outW) {
    int x0 = std::max(0, (int)b.x0), y0 = std::max(0, (int)b.y0);
    int x1 = std::min(w, (int)ceilf(b.x1)), y1 = std::min(h, (int)ceilf(b.y1));
    int cw = std::max(1, x1 - x0), ch = std::max(1, y1 - y0);
    int dw = std::max(1, (int)lroundf((float)cw * REC_H / ch));
    dw = std::min(dw, 640);   // 限长防爆显存
    outW = dw;
    out.resize((size_t)3 * REC_H * dw);
    for (int y = 0; y < REC_H; y++) {
        int sy = y0 + (int)((float)y * ch / REC_H);
        sy = std::min(sy, h - 1);
        for (int x = 0; x < dw; x++) {
            int sx = x0 + (int)((float)x * cw / dw);
            sx = std::min(sx, w - 1);
            for (int c = 0; c < 3; c++) {
                float v = (float)rgba[((size_t)sy * w + sx) * 4 + c];
                out[(size_t)c * REC_H * dw + (size_t)y * dw + x] = (v / 255.0f - 0.5f) / 0.5f;
            }
        }
    }
}

std::pair<std::string, float> ctcDecode(const float *logits, int T, int C) {
    std::string text;
    float conf = 0; int cnt = 0;
    int prev = 0;   // blank = 0
    for (int t = 0; t < T; t++) {
        int best = 0; float bv = logits[(size_t)t * C];
        for (int c = 1; c < C; c++) {
            float v = logits[(size_t)t * C + c];
            if (v > bv) { bv = v; best = c; }
        }
        if (best != 0 && best != prev) {
            if (best - 1 < (int)g.dict.size()) {
                text += g.dict[best - 1];
                conf += bv; cnt++;
            }
        }
        prev = best;
    }
    return { text, cnt ? conf / cnt : 0.0f };
}

} // namespace

BOOL MatisuOcrReady(void) {
    if (g.ready) return YES;
    @autoreleasepool {
        return initEngine() ? YES : NO;
    }
}

NSArray<MAOcrItem*>* MatisuOcrRegion(int x1, int y1, int x2, int y2) {
    NSMutableArray<MAOcrItem*> *result = [NSMutableArray array];
    if (!initEngine()) { ocrLog("initEngine failed, OCR unavailable"); return result; }

    std::vector<uint8_t> rgba;
    int w = 0, h = 0;
    if (!grabFrame(rgba, w, h)) { ocrLog("grabFrame FAILED"); return result; }

    // 区域归一
    if (x1 == 0 && y1 == 0 && x2 == 0 && y2 == 0) { x1 = 0; y1 = 0; x2 = w; y2 = h; }
    x1 = std::max(0, x1); y1 = std::max(0, y1);
    x2 = std::min(w, x2); y2 = std::min(h, y2);
    int rw = x2 - x1, rh = y2 - y1;
    if (rw < 8 || rh < 8) return result;

    // ---- det ----
    float scale = std::min((float)DET_SIDE / rw, (float)DET_SIDE / rh);
    int dw = std::min(DET_SIDE, ((int)(rw * scale) + 31) / 32 * 32);
    int dh = std::min(DET_SIDE, ((int)(rh * scale) + 31) / 32 * 32);
    // 区域像素抠出（简化：整帧 det，再过滤区域——区域 det 更快但实现长，先整帧）
    dw = std::min(DET_SIDE, (w + 31) / 32 * 32);
    dh = std::min(DET_SIDE, (h + 31) / 32 * 32);
    std::vector<float> input;
    preprocessDet(rgba, w, h, dw, dh, input);

    OrtMemoryInfo *mi = nullptr;
    g.api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &mi);
    OrtAllocator *alloc = nullptr;
    g.api->CreateAllocator(g.det, mi, &alloc);

    int64_t detShape[4] = {1, 3, dh, dw};
    OrtValue *detIn = nullptr;
    g.api->CreateTensorWithDataAsOrtValue(mi, input.data(), input.size() * sizeof(float),
                                          detShape, 4, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &detIn);
    const char *detInNames[1], *detOutNames[1];
    OrtValue *detOut = nullptr;
    {
        // 取输入输出名（假设单输入单输出，PP-OCR det 标准）
        size_t nin = 0, nout = 0;
        g.api->SessionGetInputCount(g.det, &nin);
        g.api->SessionGetOutputCount(g.det, &nout);
        char *nm = nullptr;
        g.api->SessionGetInputName(g.det, 0, alloc, &nm);
        detInNames[0] = nm;
        char *on = nullptr;
        g.api->SessionGetOutputName(g.det, 0, alloc, &on);
        detOutNames[0] = on;
    }
    OrtStatus *st = g.api->Run(g.det, nullptr, detInNames, (const OrtValue *const *)&detIn, 1,
                               detOutNames, 1, &detOut);
    if (st) { ocrLogStatus(g.api, "det Run", st); g.api->ReleaseStatus(st); goto cleanup0; }
    {
        float *prob = nullptr;
        g.api->GetTensorMutableData(detOut, (void **)&prob);
        OrtTensorTypeAndShapeInfo *tsi = nullptr;
        g.api->GetTensorTypeAndShape(detOut, &tsi);
        size_t ndim = 0;
        g.api->GetDimensionsCount(tsi, &ndim);
        int64_t dims[4] = {0};
        g.api->GetDimensions(tsi, dims, ndim);
        int ph = (int)dims[ndim - 2], pw = (int)dims[ndim - 1];
        g.api->ReleaseTensorTypeAndShapeInfo(tsi);

        auto boxes = postprocessDet(prob, pw, ph, w, h);
        ocrLog("frame %dx%d det %dx%d -> %zu boxes", w, h, pw, ph, boxes.size());

        // ---- rec ----
        for (const auto &b : boxes) {
            // 区域过滤：框中心需在请求区域内
            float cx = (b.x0 + b.x1) / 2, cy = (b.y0 + b.y1) / 2;
            if (cx < x1 || cx >= x2 || cy < y1 || cy >= y2) continue;
            std::vector<float> rin;
            int rw2 = 0;
            preprocessRec(rgba, w, h, b, rin, rw2);
            int64_t rshape[4] = {1, 3, REC_H, rw2};
            OrtValue *rin_t = nullptr;
            g.api->CreateTensorWithDataAsOrtValue(mi, rin.data(), rin.size() * sizeof(float),
                                                  rshape, 4, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &rin_t);
            const char *rinNames[1], *routNames[1];
            char *nm2 = nullptr; g.api->SessionGetInputName(g.rec, 0, alloc, &nm2); rinNames[0] = nm2;
            char *on2 = nullptr; g.api->SessionGetOutputName(g.rec, 0, alloc, &on2); routNames[0] = on2;
            OrtValue *rout = nullptr;
            st = g.api->Run(g.rec, nullptr, rinNames, (const OrtValue *const *)&rin_t, 1, routNames, 1, &rout);
            if (st) { ocrLogStatus(g.api, "rec Run", st); g.api->ReleaseStatus(st); g.api->ReleaseValue(rin_t); continue; }
            float *logits = nullptr;
            g.api->GetTensorMutableData(rout, (void **)&logits);
            OrtTensorTypeAndShapeInfo *rti = nullptr;
            g.api->GetTensorTypeAndShape(rout, &rti);
            size_t rnd = 0; g.api->GetDimensionsCount(rti, &rnd);
            int64_t rd[3] = {0}; g.api->GetDimensions(rti, rd, rnd);
            g.api->ReleaseTensorTypeAndShapeInfo(rti);
            int T = (int)rd[rnd - 2], C = (int)rd[rnd - 1];
            auto [text, conf] = ctcDecode(logits, T, C);
            if (!text.empty()) {
                MAOcrItem *item = [[MAOcrItem alloc] init];
                item.text = @(text.c_str());
                item.score = conf;
                item.x = (int)b.x0; item.y = (int)b.y0;
                item.w = (int)(b.x1 - b.x0); item.h = (int)(b.y1 - b.y0);
                [result addObject:item];
            }
            g.api->ReleaseValue(rout);
            g.api->ReleaseValue(rin_t);
        }
        g.api->ReleaseValue(detOut);
    }
cleanup0:
    g.api->ReleaseValue(detIn);
    g.api->ReleaseMemoryInfo(mi);
    if (alloc) g.api->ReleaseAllocator(alloc);
    return result;
}
