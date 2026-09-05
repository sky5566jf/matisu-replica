package com.matisu.auto

import android.graphics.Bitmap
import android.graphics.Color

/**
 * Android 设备端图色（帧源 ProjectionService，颜色契约 BBGGRR 与原版/iOS 一致）。
 * 解析："BBGGRR" 或 "BBGGRR-DRDGDB"（偏色），| 分隔多色。
 */
object ColorFind {

    private class Spec(val r: Int, val g: Int, val b: Int, val dr: Int, val dg: Int, val db: Int)

    private fun parseOne(seg: String): Spec? {
        var s = seg.trim()
        if (s.startsWith("0x") || s.startsWith("0X")) s = s.substring(2)
        val parts = s.split('-')
        if (parts[0].length != 6) return null
        val v = parts[0].toIntOrNull(16) ?: return null
        var dr = 0; var dg = 0; var db = 0
        if (parts.size > 1 && parts[1].length == 6) {
            dr = parts[1].substring(0, 2).toIntOrNull(16) ?: 0
            dg = parts[1].substring(2, 4).toIntOrNull(16) ?: 0
            db = parts[1].substring(4, 6).toIntOrNull(16) ?: 0
        }
        // BBGGRR
        return Spec(v and 0xFF, (v shr 8) and 0xFF, (v shr 16) and 0xFF, dr, dg, db)
    }

    private fun parseMulti(spec: String): List<Spec> =
        spec.split('|').mapNotNull { parseOne(it) }

    private fun match(pixel: Int, specs: List<Spec>, tol: Int): Boolean {
        val pr = Color.red(pixel); val pg = Color.green(pixel); val pb = Color.blue(pixel)
        for (cs in specs) {
            val dr = kotlin.math.abs(pr - cs.r); val dg = kotlin.math.abs(pg - cs.g); val db = kotlin.math.abs(pb - cs.b)
            if (dr <= maxOf(cs.dr, tol) && dg <= maxOf(cs.dg, tol) && db <= maxOf(cs.db, tol)) return true
        }
        return false
    }

    private fun tolOf(sim: Double): Int {
        val s = if (sim <= 0) 0.9 else if (sim > 1) 1.0 else sim
        return ((1.0 - s) * 255.0 + 0.5).toInt()
    }

    private fun normRegion(f: Bitmap, x1: Int, y1: Int, x2: Int, y2: Int): IntArray {
        if (x1 == 0 && y1 == 0 && x2 == 0 && y2 == 0) return intArrayOf(0, 0, f.width, f.height)
        return intArrayOf(x1.coerceIn(0, f.width), y1.coerceIn(0, f.height), x2.coerceIn(0, f.width), y2.coerceIn(0, f.height))
    }

    /** 区域找色：命中返回 (x,y)，未中返回 (-1,-1)。dir 0=左上首个，1=中心最近，2/3/4 同 iOS */
    fun findColor(x1: Int, y1: Int, x2: Int, y2: Int, color: String, dir: Int, sim: Double): Pair<Int, Int> {
        val f = ProjectionService.latestFrame() ?: return Pair(-1, -1)
        val specs = parseMulti(color)
        if (specs.isEmpty()) return Pair(-1, -1)
        val tol = tolOf(sim)
        val (X1, Y1, X2, Y2) = normRegion(f, x1, y1, x2, y2)

        if (dir == 0) {
            for (y in Y1 until Y2) for (x in X1 until X2)
                if (match(f.getPixel(x, y), specs, tol)) return Pair(x, y)
            return Pair(-1, -1)
        }
        var bestX = -1; var bestY = -1
        var bestScore = -1L; var bestD = Double.MAX_VALUE
        val cx0 = f.width / 2.0; val cy0 = f.height / 2.0
        for (y in Y1 until Y2) for (x in X1 until X2) {
            if (!match(f.getPixel(x, y), specs, tol)) continue
            when (dir) {
                2 -> { val s = y.toLong() * f.width + x; if (s > bestScore) { bestScore = s; bestX = x; bestY = y } }
                3 -> { val s = y.toLong() * f.width + (f.width - x); if (s > bestScore) { bestScore = s; bestX = x; bestY = y } }
                4 -> { val s = (f.height - y).toLong() * f.width + x; if (s > bestScore) { bestScore = s; bestX = x; bestY = y } }
                else -> { val d = (x - cx0) * (x - cx0) + (y - cy0) * (y - cy0); if (d < bestD) { bestD = d; bestX = x; bestY = y } }
            }
        }
        return Pair(bestX, bestY)
    }

    fun cmpColor(x: Int, y: Int, color: String, sim: Double): Int {
        val f = ProjectionService.latestFrame() ?: return 0
        if (x < 0 || y < 0 || x >= f.width || y >= f.height) return 0
        val specs = parseMulti(color)
        return if (specs.isNotEmpty() && match(f.getPixel(x, y), specs, tolOf(sim))) 1 else 0
    }

    fun cmpColorEx(multi: String, sim: Double): Int {
        val f = ProjectionService.latestFrame() ?: return 0
        val tol = tolOf(sim)
        for (pt in multi.split(',')) {
            val a = pt.split('|')
            if (a.size < 3) return 0
            val x = a[0].toIntOrNull() ?: return 0
            val y = a[1].toIntOrNull() ?: return 0
            val specs = parseMulti(a.subList(2, a.size).joinToString("|"))
            if (specs.isEmpty() || x < 0 || y < 0 || x >= f.width || y >= f.height) return 0
            if (!match(f.getPixel(x, y), specs, tol)) return 0
        }
        return 1
    }

    fun getColorNum(x1: Int, y1: Int, x2: Int, y2: Int, color: String, sim: Double): Int {
        val f = ProjectionService.latestFrame() ?: return 0
        val specs = parseMulti(color)
        if (specs.isEmpty()) return 0
        val tol = tolOf(sim)
        val (X1, Y1, X2, Y2) = normRegion(f, x1, y1, x2, y2)
        var cnt = 0
        for (y in Y1 until Y2) for (x in X1 until X2)
            if (match(f.getPixel(x, y), specs, tol)) cnt++
        return cnt
    }

    /** 单点取色（0xBBGGRR；无帧 -1） */
    fun getPixel(x: Int, y: Int): Int {
        val f = ProjectionService.latestFrame() ?: return -1
        if (x < 0 || y < 0 || x >= f.width || y >= f.height) return -1
        val p = f.getPixel(x, y)
        return (Color.blue(p) shl 16) or (Color.green(p) shl 8) or Color.red(p)   // -> BBGGRR
    }

    // ---------------- 多点找色（对齐 iOS ColorFind.m MatisuFindMultiColor 语义） ----------------

    /** 偏移点：dx,dy + 单色 Spec */
    private class OffPt(val dx: Int, val dy: Int, val cs: Spec)

    /** offset_color 解析："x|y|color,x|y|color,..."（color 内可带 - 偏色，| 分隔多色） */
    private fun parseOffsets(offset: String): List<OffPt> {
        val out = ArrayList<OffPt>()
        for (seg in offset.split(',')) {
            if (seg.isBlank()) continue
            val a = seg.split('|')
            if (a.size < 3) continue
            val dx = a[0].trim().toIntOrNull() ?: continue
            val dy = a[1].trim().toIntOrNull() ?: continue
            val cs = parseOne(a.subList(2, a.size).joinToString("|")) ?: continue
            out.add(OffPt(dx, dy, cs))
        }
        return out
    }

    private fun matchOne(pixel: Int, cs: Spec, tol: Int): Boolean {
        val pr = Color.red(pixel); val pg = Color.green(pixel); val pb = Color.blue(pixel)
        return kotlin.math.abs(pr - cs.r) <= maxOf(cs.dr, tol) &&
               kotlin.math.abs(pg - cs.g) <= maxOf(cs.dg, tol) &&
               kotlin.math.abs(pb - cs.b) <= maxOf(cs.db, tol)
    }

    /**
     * 区域多点找色：先按 dir 找 firstColor 首点，再验全部偏移点。
     * 命中返回 (x,y)，未中 (-1,-1)。
     */
    fun findMultiColor(x1: Int, y1: Int, x2: Int, y2: Int, first: String, offset: String, dir: Int, sim: Double): Pair<Int, Int> {
        val f = ProjectionService.latestFrame() ?: return Pair(-1, -1)
        val firstSpecs = parseMulti(first)
        if (firstSpecs.isEmpty()) return Pair(-1, -1)
        val offs = parseOffsets(offset)
        val tol = tolOf(sim)
        val (X1, Y1, X2, Y2) = normRegion(f, x1, y1, x2, y2)

        var found = false; var bx = -1; var by = -1
        var bestScore = -1L; var bestD = Double.MAX_VALUE
        for (yy in Y1 until Y2) for (xx in X1 until X2) {
            if (!match(f.getPixel(xx, yy), firstSpecs, tol)) continue
            var all = true
            for (o in offs) {
                val px = xx + o.dx; val py = yy + o.dy
                if (px < 0 || py < 0 || px >= f.width || py >= f.height ||
                    !matchOne(f.getPixel(px, py), o.cs, tol)) { all = false; break }
            }
            if (!all) continue
            when (dir) {
                0 -> return Pair(xx, yy)   // 左上首个
                2 -> { val s = yy.toLong() * f.width + xx; if (s > bestScore) { bestScore = s; bx = xx; by = yy; found = true } }
                3 -> { val s = yy.toLong() * f.width + (f.width - xx); if (s > bestScore) { bestScore = s; bx = xx; by = yy; found = true } }
                4 -> { val s = (f.height - yy).toLong() * f.width + xx; if (s > bestScore) { bestScore = s; bx = xx; by = yy; found = true } }
                else -> { val d = (xx - f.width / 2.0) * (xx - f.width / 2.0) + (yy - f.height / 2.0) * (yy - f.height / 2.0); if (d < bestD) { bestD = d; bx = xx; by = yy; found = true } }
            }
        }
        return if (found) Pair(bx, by) else Pair(-1, -1)
    }

    /** 区域多点找色返回所有命中："x,y;x,y,..."；无命中返回 "" */
    fun findMultiColorAll(x1: Int, y1: Int, x2: Int, y2: Int, first: String, offset: String, sim: Double): String {
        val f = ProjectionService.latestFrame() ?: return ""
        val firstSpecs = parseMulti(first)
        if (firstSpecs.isEmpty()) return ""
        val offs = parseOffsets(offset)
        val tol = tolOf(sim)
        val (X1, Y1, X2, Y2) = normRegion(f, x1, y1, x2, y2)
        val sb = StringBuilder()
        for (yy in Y1 until Y2) for (xx in X1 until X2) {
            if (!match(f.getPixel(xx, yy), firstSpecs, tol)) continue
            var all = true
            for (o in offs) {
                val px = xx + o.dx; val py = yy + o.dy
                if (px < 0 || py < 0 || px >= f.width || py >= f.height ||
                    !matchOne(f.getPixel(px, py), o.cs, tol)) { all = false; break }
            }
            if (all) {
                if (sb.isNotEmpty()) sb.append(';')
                sb.append(xx).append(',').append(yy)
            }
        }
        return sb.toString()
    }

    /** 区域像素数组（BBGGRR 整数，行优先）；区域 0,0,0,0 = 全屏 */
    fun getScreenPixel(x1: Int, y1: Int, x2: Int, y2: Int): IntArray? {
        val f = ProjectionService.latestFrame() ?: return null
        val (X1, Y1, X2, Y2) = normRegion(f, x1, y1, x2, y2)
        if (X2 <= X1 || Y2 <= Y1) return null
        val out = IntArray((X2 - X1) * (Y2 - Y1))
        var i = 0
        for (yy in Y1 until Y2) for (xx in X1 until X2) {
            val p = f.getPixel(xx, yy)
            out[i++] = (Color.blue(p) shl 16) or (Color.green(p) shl 8) or Color.red(p)
        }
        return out
    }

    // ---------------- 画面静止检测（对齐 iOS：区域 8x8 网格 FNV 哈希 + 缓存比对） ----------------
    private val deadHash = HashMap<String, Pair<Long, Long>>()   // key -> (hash, timestampMs)

    fun isDisplayDead(x1: Int, y1: Int, x2: Int, y2: Int, timeout: Double): Int {
        val f = ProjectionService.latestFrame() ?: return 0
        val (X1, Y1, X2, Y2) = normRegion(f, x1, y1, x2, y2)
        var h = 1469598103934665603UL
        val steps = 8
        for (sy in 0 until steps) for (sx in 0 until steps) {
            val xx = X1 + (X2 - X1) * sx / steps
            val yy = Y1 + (Y2 - Y1) * sy / steps
            if (xx >= f.width || yy >= f.height) continue
            h = (h xor (getPixel(xx, yy).toLong().toULong())) * 1099511628211UL
        }
        val key = "$X1,$Y1,$X2,$Y2"
        val now = System.currentTimeMillis()
        val prev = deadHash[key]
        deadHash[key] = Pair(h.toLong(), now)
        if (prev == null) return 0   // 首次采样无法判断，按"有变化"处理
        val (ph, pt) = prev
        return if (ph == h.toLong() && (now - pt) >= timeout * 1000) 1 else 0
    }

    /** 两个颜色差值之和（|dr|+|dg|+|db|） */
    fun colorDiff(c1: String, c2: String): Int {
        fun rgb(c: String): IntArray? {
            var s = c.trim()
            if (s.startsWith("0x") || s.startsWith("0X")) s = s.substring(2)
            val v = s.take(6).toIntOrNull(16) ?: return null
            return intArrayOf(v and 0xFF, (v shr 8) and 0xFF, (v shr 16) and 0xFF)   // BBGGRR -> r,g,b
        }
        val a = rgb(c1) ?: return -1
        val b = rgb(c2) ?: return -1
        return kotlin.math.abs(a[0] - b[0]) + kotlin.math.abs(a[1] - b[1]) + kotlin.math.abs(a[2] - b[2])
    }
}
