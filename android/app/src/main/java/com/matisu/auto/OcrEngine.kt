package com.matisu.auto

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.graphics.Bitmap
import java.io.File
import java.nio.FloatBuffer
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * 设备端 OCR（PP-OCRv6 small / onnxruntime-android）——与 iOS OcrEngine.mm 同构移植。
 * 管线：latestFrame → det(DB 检测) → 文本框 crop → rec(CTC 识别) → 文本+坐标。
 * 模型不随 APK 分发：<externalFilesDir>/ocr/{det.onnx,rec.onnx,dict.txt}（adb push 分发，31MB）。
 */
object OcrEngine {
    class Item(val text: String, val score: Float, val x: Int, val y: Int, val w: Int, val h: Int)

    private const val DET_SIDE = 960      // det 输入边长（32 倍数）
    private const val REC_H = 48          // rec 输入高
    private const val DET_THRESH = 0.3f
    private const val DET_BOX_THRESH = 0.5f
    private const val DET_UNCLIP = 1.6f

    private var ready = false
    private var failed = false
    private var env: OrtEnvironment? = null
    private var det: OrtSession? = null
    private var rec: OrtSession? = null
    private var dict: List<String> = emptyList()

    private fun ocrDir(ctx: Context?): File? =
        ctx?.getExternalFilesDir("ocr") ?: ctx?.let { File(it.filesDir, "ocr") }

    /** 模型三件是否齐（不初始化引擎，只查文件） */
    fun modelsPresent(ctx: Context?): Boolean {
        val d = ocrDir(ctx) ?: return false
        return File(d, "det.onnx").isFile && File(d, "rec.onnx").isFile && File(d, "dict.txt").isFile
    }

    @Synchronized
    private fun initEngine(ctx: Context?): Boolean {
        if (ready) return true
        if (failed) return false
        try {
            val dir = ocrDir(ctx)
            val detFile = File(dir, "det.onnx")
            val recFile = File(dir, "rec.onnx")
            val dictFile = File(dir, "dict.txt")
            if (dir == null || !detFile.isFile || !recFile.isFile || !dictFile.isFile) {
                EngineLog.append("[WARN] OCR 模型缺失: ${dir ?: "?"}（需 det.onnx/rec.onnx/dict.txt，adb push 到 Android/data/com.matisu.auto/files/ocr/）\n")
                failed = true
                return false
            }
            val e = OrtEnvironment.getEnvironment()
            val opt = OrtSession.SessionOptions().apply { setIntraOpNumThreads(2) }
            env = e
            det = e.createSession(detFile.absolutePath, opt)
            rec = e.createSession(recFile.absolutePath, opt)
            dict = dictFile.readLines(Charsets.UTF_8).filter { it.isNotEmpty() }
            if (dict.isEmpty()) { EngineLog.append("[WARN] OCR dict 为空\n"); failed = true; return false }
            ready = true
            EngineLog.append("[OCR] init ok, dict=${dict.size} entries, det=${detFile.length() / 1024}KB rec=${recFile.length() / 1024}KB\n")
            return true
        } catch (t: Throwable) {
            EngineLog.append("[WARN] OCR init FAILED: ${t.message}\n")
            failed = true
            return false
        }
    }

    // ---------------- det 前处理：Bitmap → 双线性 resize → CHW float（ImageNet 归一化） ----------------
    private fun preprocessDet(px: IntArray, w: Int, h: Int, dw: Int, dh: Int, out: FloatArray) {
        val mean = floatArrayOf(0.485f, 0.456f, 0.406f)
        val std = floatArrayOf(0.229f, 0.224f, 0.225f)
        for (y in 0 until dh) {
            val sy = y.toFloat() * h / dh
            val y0 = sy.toInt(); val fy = sy - y0
            val y1 = min(y0 + 1, h - 1)
            for (x in 0 until dw) {
                val sx = x.toFloat() * w / dw
                val x0 = sx.toInt(); val fx = sx - x0
                val x1 = min(x0 + 1, w - 1)
                val p00 = px[y0 * w + x0]; val p01 = px[y0 * w + x1]
                val p10 = px[y1 * w + x0]; val p11 = px[y1 * w + x1]
                for (c in 0 until 3) {
                    // Android Int 像素 = ARGB；R=(shr 16), G=(shr 8), B=低 8
                    val shift = when (c) { 0 -> 16; 1 -> 8; else -> 0 }
                    val v00 = ((p00 shr shift) and 0xFF).toFloat()
                    val v01 = ((p01 shr shift) and 0xFF).toFloat()
                    val v10 = ((p10 shr shift) and 0xFF).toFloat()
                    val v11 = ((p11 shr shift) and 0xFF).toFloat()
                    val v = (v00 * (1 - fx) + v01 * fx) * (1 - fy) + (v10 * (1 - fx) + v11 * fx) * fy
                    out[c * dw * dh + y * dw + x] = (v / 255.0f - mean[c]) / std[c]
                }
            }
        }
    }

    private class DetBox(var x0: Float, var y0: Float, var x1: Float, var y1: Float, val score: Float)

    // ---------------- det 后处理：概率图 → 二值化 → BFS 连通域 → unclip（同 iOS） ----------------
    private fun postprocessDet(prob: FloatArray, pw: Int, ph: Int, ow: Int, oh: Int): List<DetBox> {
        val bin = ByteArray(pw * ph)
        for (i in bin.indices) bin[i] = if (prob[i] > DET_THRESH) 1 else 0
        val label = IntArray(pw * ph)
        val boxes = ArrayList<DetBox>()
        val stack = IntArray(pw * ph)
        var cur = 0
        for (y in 0 until ph) {
            for (x in 0 until pw) {
                val idx = y * pw + x
                if (bin[idx].toInt() == 0 || label[idx] != 0) continue
                cur++
                var minx = x; var maxx = x; var miny = y; var maxy = y
                var scoreSum = 0f; var cnt = 0
                var sp = 0
                stack[sp++] = idx
                label[idx] = cur
                while (sp > 0) {
                    val ci = stack[--sp]
                    val cy = ci / pw; val cx = ci % pw
                    if (cx < minx) minx = cx; if (cx > maxx) maxx = cx
                    if (cy < miny) miny = cy; if (cy > maxy) maxy = cy
                    scoreSum += prob[ci]; cnt++
                    for (dy in -1..1) for (dx in -1..1) {
                        val nx = cx + dx; val ny = cy + dy
                        if (nx < 0 || ny < 0 || nx >= pw || ny >= ph) continue
                        val ni = ny * pw + nx
                        if (bin[ni].toInt() != 0 && label[ni] == 0) { label[ni] = cur; stack[sp++] = ni }
                    }
                }
                if (cnt < 8) continue   // 过滤噪点
                val avg = scoreSum / cnt
                if (avg < DET_BOX_THRESH) continue
                val bw = (maxx - minx).toFloat(); val bh = (maxy - miny).toFloat()
                val area = bw * bh
                val dist = area * DET_UNCLIP / (2.0f * (bw + bh) + 1e-5f)
                val kx = ow.toFloat() / pw; val ky = oh.toFloat() / ph
                boxes.add(DetBox(
                    max(0f, minx - dist) * kx, max(0f, miny - dist) * ky,
                    min(pw.toFloat(), maxx + dist) * kx, min(ph.toFloat(), maxy + dist) * ky,
                    avg))
            }
        }
        // 行序排序：y 差 >10 视为不同行（同 iOS），否则按 x
        boxes.sortWith { a, b2 ->
            if (abs(a.y0 - b2.y0) > 10) a.y0.compareTo(b2.y0) else a.x0.compareTo(b2.x0)
        }
        return boxes
    }

    // ---------------- rec 前处理：crop → 高 48 等比 → CHW ((v/255-0.5)/0.5) ----------------
    private fun preprocessRec(px: IntArray, w: Int, h: Int, b: DetBox, dw: Int): FloatArray {
        val x0 = max(0, b.x0.toInt()); val y0 = max(0, b.y0.toInt())
        val x1 = min(w, ceil(b.x1.toDouble()).toInt()); val y1 = min(h, ceil(b.y1.toDouble()).toInt())
        val cw = max(1, x1 - x0); val ch = max(1, y1 - y0)
        val out = FloatArray(3 * REC_H * dw)
        for (y in 0 until REC_H) {
            val sy = min(y0 + (y.toFloat() * ch / REC_H).toInt(), h - 1)
            for (x in 0 until dw) {
                val sx = min(x0 + (x.toFloat() * cw / dw).toInt(), w - 1)
                val p = px[sy * w + sx]
                out[0 * REC_H * dw + y * dw + x] = (((p shr 16) and 0xFF) / 255.0f - 0.5f) / 0.5f
                out[1 * REC_H * dw + y * dw + x] = (((p shr 8) and 0xFF) / 255.0f - 0.5f) / 0.5f
                out[2 * REC_H * dw + y * dw + x] = ((p and 0xFF) / 255.0f - 0.5f) / 0.5f
            }
        }
        return out
    }

    // ---------------- CTC 解码（blank=0，dict[best-1]） ----------------
    private fun ctcDecode(logits: FloatArray, T: Int, C: Int): Pair<String, Float> {
        val sb = StringBuilder()
        var conf = 0f; var cnt = 0
        var prev = 0
        for (t in 0 until T) {
            var best = 0; var bv = logits[t * C]
            for (c in 1 until C) {
                val v = logits[t * C + c]
                if (v > bv) { bv = v; best = c }
            }
            if (best != 0 && best != prev) {
                if (best - 1 < dict.size) {
                    sb.append(dict[best - 1])
                    conf += bv; cnt++
                }
            }
            prev = best
        }
        return Pair(sb.toString(), if (cnt > 0) conf / cnt else 0f)
    }

    /**
     * 对区域 (x1,y1,x2,y2) OCR；0,0,0,0=全屏。返回按行序排列的结果。
     * 与 iOS 一致：整帧 det（输出 32 倍数、上限 960），框中心在区域内才 rec。
     */
    fun region(ctx: Context?, x1i: Int, y1i: Int, x2i: Int, y2i: Int): List<Item> {
        if (!initEngine(ctx)) return emptyList()
        val bmp = ProjectionService.latestFrame() ?: return emptyList()
        val e = env ?: return emptyList()
        val d = det ?: return emptyList()
        val r = rec ?: return emptyList()

        val w = bmp.width; val h = bmp.height
        var x1 = x1i; var y1 = y1i; var x2 = x2i; var y2 = y2i
        if (x1 == 0 && y1 == 0 && x2 == 0 && y2 == 0) { x2 = w; y2 = h }
        x1 = max(0, x1); y1 = max(0, y1); x2 = min(w, x2); y2 = min(h, y2)
        if (x2 - x1 < 8 || y2 - y1 < 8) return emptyList()

        val px = IntArray(w * h)
        bmp.getPixels(px, 0, w, 0, 0, w, h)

        // ---- det（整帧，同 iOS 简化策略） ----
        val dw = min(DET_SIDE, (w + 31) / 32 * 32)
        val dh = min(DET_SIDE, (h + 31) / 32 * 32)
        val din = FloatArray(3 * dw * dh)
        preprocessDet(px, w, h, dw, dh, din)
        var items: List<Item> = emptyList()
        try {
            OnnxTensor.createTensor(e, FloatBuffer.wrap(din), longArrayOf(1, 3, dh.toLong(), dw.toLong())).use { t ->
                d.run(java.util.Collections.singletonMap(d.inputNames.iterator().next(), t)).use { res ->
                    // 兼容 [1,1,H,W] / [1,2,H,W]：剥前导维取 [H][W]（多通道取第一通道概率图）
                    var vd: Any? = res[0].value
                    while (vd is Array<*> && vd.size > 0) {
                        val sub = vd[0]
                        if (sub is FloatArray) break  // vd 已是 [H][W]
                        vd = sub
                    }
                    val prob = vd as? Array<FloatArray>
                        ?: throw IllegalStateException("det output unexpected shape")
                    val ph = prob.size; val pw = prob[0].size
                    val flat = FloatArray(ph * pw)
                    for (yy in 0 until ph) System.arraycopy(prob[yy], 0, flat, yy * pw, pw)
                    val boxes = postprocessDet(flat, pw, ph, w, h)
                    // ---- rec ----
                    val out = ArrayList<Item>()
                    for (b in boxes) {
                        val cx = (b.x0 + b.x1) / 2; val cy = (b.y0 + b.y1) / 2
                        if (cx < x1 || cx >= x2 || cy < y1 || cy >= y2) continue
                        val bx0 = max(0, b.x0.toInt()); val by0 = max(0, b.y0.toInt())
                        val bx1 = min(w, ceil(b.x1.toDouble()).toInt()); val by1 = min(h, ceil(b.y1.toDouble()).toInt())
                        val cw = max(1, bx1 - bx0); val chh = max(1, by1 - by0)
                        var rw = max(1, (cw.toFloat() * REC_H / chh).roundToInt())
                        rw = min(rw, 640)   // 限长（同 iOS）
                        val rin = preprocessRec(px, w, h, b, rw)
                        OnnxTensor.createTensor(e, FloatBuffer.wrap(rin), longArrayOf(1, 3, REC_H.toLong(), rw.toLong())).use { rt ->
                            r.run(java.util.Collections.singletonMap(r.inputNames.iterator().next(), rt)).use { rres ->
                                // 兼容 [1,T,C] / [1,1,T,C]：剥掉前导 1 维，得到 [T][C]（同 iOS 取最后两维）
                                var v: Any? = rres[0].value
                                while (v is Array<*> && v.size > 0) {
                                    val sub = v[0]
                                    if (sub is Array<*> && sub.size > 0 && sub[0] is FloatArray) break  // v 已是 [T][C]
                                    v = sub
                                }
                                val logits3 = v as? Array<FloatArray>
                                    ?: throw IllegalStateException("rec output unexpected shape")
                                val T = logits3.size; val C = logits3[0].size
                                val flatL = FloatArray(T * C)
                                for (tt in 0 until T) System.arraycopy(logits3[tt], 0, flatL, tt * C, C)
                                val (text, conf) = ctcDecode(flatL, T, C)
                                if (text.isNotEmpty()) {
                                    out.add(Item(text, conf, bx0, by0, bx1 - bx0, by1 - by0))
                                }
                            }
                        }
                    }
                    items = out
                }
            }
        } catch (t: Throwable) {
            EngineLog.append("[WARN] OCR run FAILED: ${t.message}\n")
        }
        return items
    }
}
