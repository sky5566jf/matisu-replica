package com.matisu.auto

import android.graphics.Bitmap
import android.graphics.BitmapFactory

/**
 * Android 设备端找图（移植 iOS PicFind.m 同源算法：SAD 9 点粗筛 + 邻域精修 + NMS；
 * Android 帧即逻辑像素，无需 iOS 的缩帧/坐标映射层）。
 * findPicEx 走 alpha 遮罩（模板 alpha<128 的像素跳过比对）。
 */
object PicFind {

    private const val MAX_TPL = 1024

    private class Tpl(val w: Int, val h: Int, val rgba: IntArray)

    private fun loadTemplate(path: String): Tpl? {
        return try {
            val opt = BitmapFactory.Options()
            opt.inPreferredConfig = Bitmap.Config.ARGB_8888
            val bmp = BitmapFactory.decodeFile(path, opt) ?: return null
            val w = bmp.width; val h = bmp.height
            if (w <= 0 || h <= 0 || w > MAX_TPL || h > MAX_TPL) { bmp.recycle(); return null }
            val px = IntArray(w * h)
            bmp.getPixels(px, 0, w, 0, 0, w, h)
            bmp.recycle()
            Tpl(w, h, px)
        } catch (_: Throwable) { null }
    }

    /** 模板像素颜色（ARGB int -> 已含 alpha；比对用 r/g/b） */
    private class Frame(val bmp: Bitmap) {
        val w = bmp.width; val h = bmp.height
        private val px = IntArray(bmp.width * bmp.height)
        init { bmp.getPixels(px, 0, w, 0, 0, w, h) }
        fun r(x: Int, y: Int) = (px[y * w + x] shr 16) and 0xFF
        fun g(x: Int, y: Int) = (px[y * w + x] shr 8) and 0xFF
        fun b(x: Int, y: Int) = px[y * w + x] and 0xFF
        fun a(x: Int, y: Int) = (px[y * w + x] ushr 24) and 0xFF
    }

    private fun scoreAt(f: Frame, t: Tpl, useMask: Boolean, px: Int, py: Int): Double {
        var diff = 0L; var cnt = 0L
        for (ty in 0 until t.h) {
            val sy = py + ty
            for (tx in 0 until t.w) {
                if (useMask && (t.rgba[ty * t.w + tx] ushr 24) < 128) continue
                val tp = t.rgba[ty * t.w + tx]
                val sx = px + tx
                diff += kotlin.math.abs(f.r(sx, sy) - ((tp shr 16) and 0xFF)) +
                        kotlin.math.abs(f.g(sx, sy) - ((tp shr 8) and 0xFF)) +
                        kotlin.math.abs(f.b(sx, sy) - (tp and 0xFF))
                cnt += 3
            }
        }
        if (cnt == 0L) return 0.0
        return 1.0 - (diff.toDouble() / cnt.toDouble()) / 255.0
    }

    private fun normRegion(f: Frame, x1: Int, y1: Int, x2: Int, y2: Int): IntArray {
        if (x1 == 0 && y1 == 0 && x2 == 0 && y2 == 0) return intArrayOf(0, 0, f.w, f.h)
        return intArrayOf(
            x1.coerceIn(0, f.w), y1.coerceIn(0, f.h),
            x2.coerceIn(0, f.w), y2.coerceIn(0, f.h))
    }

    private fun matchTemplate(f: Frame, t: Tpl, X1: Int, Y1: Int, X2: Int, Y2: Int,
                              sim: Double, useMask: Boolean): Pair<Int, Int>? {
        val ex2 = minOf(X2 - t.w, f.w - t.w)
        val ey2 = minOf(Y2 - t.h, f.h - t.h)
        if (ex2 < X1 || ey2 < Y1) return null
        val step = maxOf(2, minOf(t.w, t.h) shr 3)

        // 粗扫：9 点预筛
        val cands = ArrayList<Int>(512)
        var y = Y1
        while (y <= ey2) {
            var x = X1
            while (x <= ex2) {
                var pre = 0L; var pc = 0L
                for (k in 0 until 9) {
                    val tx = (k % 3) * (t.w shr 2) + (t.w shr 3)
                    val ty = (k / 3) * (t.h shr 2) + (t.h shr 3)
                    if (useMask && (t.rgba[ty * t.w + tx] ushr 24) < 128) continue
                    val tp = t.rgba[ty * t.w + tx]
                    pre += kotlin.math.abs(f.r(x + tx, y + ty) - ((tp shr 16) and 0xFF)) +
                           kotlin.math.abs(f.g(x + tx, y + ty) - ((tp shr 8) and 0xFF)) +
                           kotlin.math.abs(f.b(x + tx, y + ty) - (tp and 0xFF))
                    pc += 3
                }
                if (pc > 0 && 1.0 - (pre.toDouble() / pc.toDouble()) / 255.0 >= sim - 0.15) {
                    cands.add(x); cands.add(y)
                }
                x += step
            }
            y += step
        }

        // 精修：候选点邻域全扫描取最优
        var found = false; var bestS = 0.0; var bx = -1; var by = -1
        for (i in 0 until cands.size step 2) {
            val cx = cands[i]; val cy = cands[i + 1]
            val x1r = maxOf(X1, cx - step); val y1r = maxOf(Y1, cy - step)
            val x2r = minOf(ex2, cx + step); val y2r = minOf(ey2, cy + step)
            for (yy in y1r..y2r) for (xx in x1r..x2r) {
                val s = scoreAt(f, t, useMask, xx, yy)
                if (s >= sim && (!found || s > bestS)) { found = true; bestS = s; bx = xx; by = yy }
            }
        }
        return if (found) Pair(bx, by) else null
    }

    /** 区域找图：命中返回 (x,y)，未中 (-1,-1)。useMask=true 时模板 alpha<128 跳过（findPicEx） */
    fun findPic(x1: Int, y1: Int, x2: Int, y2: Int, path: String, sim: Double, useMask: Boolean): Pair<Int, Int> {
        val t = loadTemplate(path) ?: return Pair(-1, -1)
        val bmp = ProjectionService.latestFrame() ?: return Pair(-1, -1)
        val f = Frame(bmp)
        if (t.w < 4 || t.h < 4 || t.w > f.w || t.h > f.h) return Pair(-1, -1)
        val (X1, Y1, X2, Y2) = normRegion(f, x1, y1, x2, y2)
        val hit = matchTemplate(f, t, X1, Y1, X2, Y2, if (sim <= 0) 0.9 else if (sim > 1) 1.0 else sim, useMask)
        return hit ?: Pair(-1, -1)
    }

    /** 全部命中点：NMS 去重（minDist=模板较大边一半），maxRet<=0 不限 */
    fun findAllPoint(x1: Int, y1: Int, x2: Int, y2: Int, path: String, sim0: Double, maxRet: Int): List<Pair<Int, Int>> {
        val out = ArrayList<Pair<Int, Int>>()
        val t = loadTemplate(path) ?: return out
        val bmp = ProjectionService.latestFrame() ?: return out
        val f = Frame(bmp)
        if (t.w < 4 || t.h < 4 || t.w > f.w || t.h > f.h) return out
        val sim = if (sim0 <= 0) 0.9 else if (sim0 > 1) 1.0 else sim0
        val (X1, Y1, X2, Y2) = normRegion(f, x1, y1, x2, y2)
        val ex2 = minOf(X2 - t.w, f.w - t.w); val ey2 = minOf(Y2 - t.h, f.h - t.h)
        if (ex2 < X1 || ey2 < Y1) return out
        val step = maxOf(2, minOf(t.w, t.h) shr 3)

        val hits = ArrayList<Pair<Int, Int>>()
        var y = Y1
        while (y <= ey2) {
            var x = X1
            while (x <= ex2) {
                // 9 点预筛
                var pre = 0L; var pc = 0L
                for (k in 0 until 9) {
                    val tx = (k % 3) * (t.w shr 2) + (t.w shr 3)
                    val ty = (k / 3) * (t.h shr 2) + (t.h shr 3)
                    val tp = t.rgba[ty * t.w + tx]
                    pre += kotlin.math.abs(f.r(x + tx, y + ty) - ((tp shr 16) and 0xFF)) +
                           kotlin.math.abs(f.g(x + tx, y + ty) - ((tp shr 8) and 0xFF)) +
                           kotlin.math.abs(f.b(x + tx, y + ty) - (tp and 0xFF))
                    pc += 3
                }
                if (pc > 0 && 1.0 - (pre.toDouble() / pc.toDouble()) / 255.0 >= sim - 0.15) {
                    // 邻域精修，任一点达标即记一个命中（与 iOS 一致每候选取首个达标点）
                    val x1r = maxOf(X1, x - step); val y1r = maxOf(Y1, y - step)
                    val x2r = minOf(ex2, x + step); val y2r = minOf(ey2, y + step)
                    loop@ for (yy in y1r..y2r) for (xx in x1r..x2r) {
                        if (scoreAt(f, t, false, xx, yy) >= sim) { hits.add(Pair(xx, yy)); break@loop }
                    }
                }
                x += step
            }
            y += step
        }
        if (hits.isEmpty()) return out
        // NMS（此处命中顺序即扫描序，按距离去重）
        val minDist = maxOf(t.w, t.h) / 2 + 1
        val minD2 = minDist * minDist
        for (h in hits) {
            var ok = true
            for (k in out) {
                val dx = h.first - k.first; val dy = h.second - k.second
                if (dx * dx + dy * dy < minD2) { ok = false; break }
            }
            if (ok) {
                out.add(h)
                if (maxRet > 0 && out.size >= maxRet) break
            }
        }
        return out
    }

    /**
     * 霍夫圆检测（移植 iOS MatisuFindCircle：Sobel 梯度 + 梯度方向投票 + 半径环验证）。
     * 返回 (cx,cy,r)，未命中 (-1,-1,-1)。
     */
    fun findCircle(x1: Int, y1: Int, x2: Int, y2: Int,
                   dp0: Int, minDist0: Int, p1: Int, p2: Int, minR0: Int, maxR0: Int): Triple<Int, Int, Int> {
        val bmp = ProjectionService.latestFrame() ?: return Triple(-1, -1, -1)
        val f = Frame(bmp)
        val dp = if (dp0 < 1) 1 else dp0
        var minR = if (minR0 < 1) 1 else minR0
        var maxR = if (maxR0 < minR) minR else maxR0
        val (X1, Y1, X2, Y2) = normRegion(f, x1, y1, x2, y2)
        val W = X2 - X1; val H = Y2 - Y1
        if (W < 8 || H < 8) return Triple(-1, -1, -1)
        if (minR > W / 2 || minR > H / 2) return Triple(-1, -1, -1)
        if (maxR > W / 2 || maxR > H / 2) maxR = minOf(W, H) / 2

        // 灰度 + Sobel
        val gray = ByteArray(W * H)
        for (yy in 0 until H) for (xx in 0 until W)
            gray[yy * W + xx] = (((f.r(X1 + xx, Y1 + yy) * 77 + f.g(X1 + xx, Y1 + yy) * 150 + f.b(X1 + xx, Y1 + yy) * 29) shr 8)).toByte()
        val AW = (W + dp - 1) / dp; val AH = (H + dp - 1) / dp
        val acc = IntArray(AW * AH)
        val thr = (if (p1 > 0) p1 else 100).toDouble()
        for (yy in 1 until H - 1) for (xx in 1 until W - 1) {
            val tl = gray[(yy - 1) * W + xx - 1].toInt() and 0xFF; val tc = gray[(yy - 1) * W + xx].toInt() and 0xFF; val tr = gray[(yy - 1) * W + xx + 1].toInt() and 0xFF
            val ml = gray[yy * W + xx - 1].toInt() and 0xFF; val mr = gray[yy * W + xx + 1].toInt() and 0xFF
            val bl = gray[(yy + 1) * W + xx - 1].toInt() and 0xFF; val bc = gray[(yy + 1) * W + xx].toInt() and 0xFF; val br = gray[(yy + 1) * W + xx + 1].toInt() and 0xFF
            val sx = ((tr + 2 * mr + br) - (tl + 2 * ml + bl)).toDouble()
            val sy = ((bl + 2 * bc + br) - (tl + 2 * tc + tr)).toDouble()
            val m = kotlin.math.sqrt(sx * sx + sy * sy)
            if (m < thr) continue
            val nx = sx / (m + 1e-6); val ny = sy / (m + 1e-6)
            for (r in minR..maxR) {
                val vx = (xx - nx * r).toInt() / dp; val vy = (yy - ny * r).toInt() / dp
                if (vx in 0 until AW && vy in 0 until AH) acc[vy * AW + vx]++
                val ux = (xx + nx * r).toInt() / dp; val uy = (yy + ny * r).toInt() / dp
                if (ux in 0 until AW && uy in 0 until AH) acc[uy * AW + ux]++
            }
        }
        // 峰值
        var bestV = 0; var bx = -1; var by = -1
        val pthr = maxOf(8, maxR - minR)
        for (yy in 1 until AH - 1) for (xx in 1 until AW - 1) {
            val v = acc[yy * AW + xx]
            if (v < pthr) continue
            var local = true
            loop@ for (dy in -1..1) for (dx in -1..1)
                if (acc[(yy + dy) * AW + xx + dx] > v) { local = false; break@loop }
            if (local && v > bestV) { bestV = v; bx = xx * dp + dp / 2; by = yy * dp + dp / 2 }
        }
        if (bestV < pthr || bx < 0) return Triple(-1, -1, -1)
        // 估半径：过圆心水平扫描，边缘梯度一致性最好的半径
        val cxg = bx + X1
        var bestR = (minR + maxR) / 2; var bestRs = -1
        for (r in minR..maxR) {
            var sc = 0
            for (a in 0 until 360 step 30) {
                val ang = Math.toRadians(a.toDouble())
                val ex = cxg + (r * kotlin.math.cos(ang)).toInt()
                val ey = by + Y1 + (r * kotlin.math.sin(ang)).toInt()
                if (ex <= 0 || ey <= 0 || ex >= f.w - 1 || ey >= f.h - 1) continue
                val gx2 = f.r(ex + 1, ey) - f.r(ex - 1, ey)
                val gy2 = f.g(ex, ey + 1) - f.g(ex, ey - 1)
                if (kotlin.math.sqrt((gx2 * gx2 + gy2 * gy2).toDouble()) >= thr / 4) sc++
            }
            if (sc > bestRs) { bestRs = sc; bestR = r }
        }
        return Triple(bx + X1, by + Y1, bestR)
    }
}
