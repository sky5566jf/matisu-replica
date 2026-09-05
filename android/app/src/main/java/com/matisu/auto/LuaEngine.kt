package com.matisu.auto

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.Vibrator
import org.luaj.vm2.Globals
import org.luaj.vm2.LuaError
import org.luaj.vm2.LuaString
import org.luaj.vm2.LuaTable
import org.luaj.vm2.LuaValue
import org.luaj.vm2.Varargs
import org.luaj.vm2.lib.OneArgFunction
import org.luaj.vm2.lib.TwoArgFunction
import org.luaj.vm2.lib.VarArgFunction
import org.luaj.vm2.lib.jse.JsePlatform
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * MatisuAuto Android 设备端 Lua 引擎（LuaJ）
 * 与 iOS 设备端引擎同契约（对齐 core.lua 清单）：
 * 触控 / 图色（含 *T table 变体）/ 找图 / OCR 桩 / strutils / 设备信息 /
 * 应用管理 / 系统控制 / 日志 / network / cipher / jsonLib|json。
 *
 * 常驻脚本中断：stop 置标志位，mSleep/sleep 下一拍抛 LuaError（原版脚本
 * 循环必带 sleep 的惯例下延迟可控）。exitScript/restartScript 走
 * __MATISU_EXIT__ / __MATISU_RESTART__ 错误码（对齐 iOS LuaEngine.mm）。
 */
object LuaEngine {

    data class RunResult(val ok: Boolean, val output: String, val error: String? = null, val globals: String? = null, val stopped: Boolean = false)

    const val ENGINE_VERSION = "2.0.1"

    private var svcThread: Thread? = null
    @Volatile var svcStop = false
    @Volatile var runStop = false   // one-shot(F5) 停止标志（ScriptServer stop 命令置位）
    @Volatile var svcRunning = false
        private set
    private val svcOut = StringBuilder()
    private val outLock = Any()
    @Volatile private var stopCb: LuaValue? = null   // setStopCallBack 注册的回调
    @Volatile private var svcSource: String? = null  // 常驻脚本源码（restartScript 用）

    /** 脚本目录（app 私有可写） */
    var scriptDir: File? = null

    private val ctx: Context? get() = AutoAccessibilityService.instance

    // ---------------- 参数解包工具（对齐 iOS maTbl*：具名字段优先，数组下标兜底） ----------------
    private fun tblGet(t: LuaValue, key: String, nth: Int): LuaValue {
        val v = t.get(key)
        return if (nth > 0 && v.isnil()) t.get(nth) else v
    }
    private fun tblInt(t: LuaValue, key: String, nth: Int, def: Int): Int {
        val v = tblGet(t, key, nth)
        return if (v.isnil()) def else v.checkint()
    }
    private fun tblNum(t: LuaValue, key: String, nth: Int, def: Double): Double {
        val v = tblGet(t, key, nth)
        return if (v.isnil()) def else v.checkdouble()
    }
    private fun tblStr(t: LuaValue, key: String, nth: Int, def: String): String {
        val v = tblGet(t, key, nth)
        return if (v.isnil()) def else v.checkjstring()
    }

    // ---------------- 函数注册 ----------------
    private fun registerFns(g: Globals, out: StringBuilder, checkStop: () -> Boolean) {
        val svc = AutoAccessibilityService.instance
        val c = ctx

        fun logf(level: String): VarArgFunction = object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val sb = StringBuilder()
                for (i in 1..args.narg()) {
                    if (i > 1) sb.append('\t')
                    sb.append(args.arg(i).tojstring())
                }
                EngineLog.append("[$level] $sb\n")
                return NIL
            }
        }

        g.set("print", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val sb = StringBuilder()
                for (i in 1..args.narg()) {
                    if (i > 1) sb.append('\t')
                    sb.append(args.arg(i).tojstring())
                }
                sb.append('\n')
                synchronized(outLock) { out.append(sb) }
                EngineLog.append(sb.toString())
                return NIL
            }
        })
        // ---------------- 触控 ----------------
        g.set("tap", object : TwoArgFunction() {
            override fun call(x: LuaValue, y: LuaValue): LuaValue {
                svc?.tap(x.checkint(), y.checkint())
                return NIL
            }
        })
        g.set("longTap", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val x = args.checkint(1); val y = args.checkint(2)
                val sec = if (args.narg() >= 3) args.checkdouble(3) else 1.0
                svc?.swipe(x, y, x + 1, y, (sec * 1000).toLong())   // 原地微动长按
                return NIL
            }
        })
        g.set("swipe", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val dur = if (args.narg() >= 5) args.checkdouble(5) else 0.2
                svc?.swipe(args.checkint(1), args.checkint(2), args.checkint(3), args.checkint(4),
                    (dur * 1000).toLong())
                return NIL
            }
        })
        g.set("touchDown", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                svc?.touchDown(args.checkint(1), args.checkint(2), args.checkint(3)); return NIL
            }
        })
        g.set("touchMove", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                svc?.touchMove(args.checkint(1), args.checkint(2), args.checkint(3)); return NIL
            }
        })
        g.set("touchUp", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                svc?.touchUp(args.checkint(1), args.checkint(2), args.checkint(3)); return NIL
            }
        })
        g.set("keyPress", object : OneArgFunction() {
            override fun call(name: LuaValue): LuaValue {
                svc?.keyPress(name.checkjstring())
                return NIL
            }
        })
        // 组合键按下/抬起：无障碍通道不支持，注册占位（对齐函数面，iOS 实现为 HID 键盘）
        g.set("keyDown", object : OneArgFunction() {
            override fun call(name: LuaValue): LuaValue { EngineLog.append("[WARN] keyDown: Android 端暂不支持组合键\n"); return NIL }
        })
        g.set("keyUp", object : OneArgFunction() {
            override fun call(name: LuaValue): LuaValue { EngineLog.append("[WARN] keyUp: Android 端暂不支持组合键\n"); return NIL }
        })
        g.set("inputText", object : OneArgFunction() {
            override fun call(text: LuaValue): LuaValue {
                svc?.inputText(text.checkjstring())
                return LuaValue.valueOf(svc != null)
            }
        })
        // ---------------- 图色（帧源 ProjectionService，颜色 BBGGRR） ----------------
        g.set("getDisplaySize", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val (w, h) = AutoAccessibilityService.displaySize()
                return LuaValue.varargsOf(LuaValue.valueOf(w), LuaValue.valueOf(h))
            }
        })
        g.set("getPixelColor", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val cv = ColorFind.getPixel(args.checkint(1), args.checkint(2))
                if (cv < 0) return NIL
                val type = if (args.narg() >= 3) args.checkint(3) else 0
                return if (type == 1) LuaValue.valueOf(cv)
                else LuaValue.valueOf(String.format("%06X", cv and 0xFFFFFF))
            }
        })
        g.set("findColor", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val (x, y) = ColorFind.findColor(
                    args.optint(1, 0), args.optint(2, 0), args.optint(3, 0), args.optint(4, 0),
                    args.checkjstring(5), args.optint(6, 0), args.optdouble(7, 0.9))
                return LuaValue.varargsOf(LuaValue.valueOf(x), LuaValue.valueOf(y))
            }
        })
        g.set("findColorT", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val t = args.arg1().checktable()
                val (x, y) = ColorFind.findColor(
                    tblInt(t, "x1", 1, 0), tblInt(t, "y1", 2, 0), tblInt(t, "x2", 3, 0), tblInt(t, "y2", 4, 0),
                    tblStr(t, "color", 5, ""), tblInt(t, "dir", 6, 0), tblNum(t, "sim", 7, 0.9))
                return LuaValue.varargsOf(LuaValue.valueOf(x), LuaValue.valueOf(y))
            }
        })
        g.set("findMultiColor", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val (x, y) = ColorFind.findMultiColor(
                    args.optint(1, 0), args.optint(2, 0), args.optint(3, 0), args.optint(4, 0),
                    args.checkjstring(5), args.optjstring(6, ""), args.optint(7, 0), args.optdouble(8, 0.9))
                return LuaValue.varargsOf(LuaValue.valueOf(x), LuaValue.valueOf(y))
            }
        })
        g.set("findMultiColorT", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val t = args.arg1().checktable()
                val (x, y) = ColorFind.findMultiColor(
                    tblInt(t, "x1", 1, 0), tblInt(t, "y1", 2, 0), tblInt(t, "x2", 3, 0), tblInt(t, "y2", 4, 0),
                    tblStr(t, "color", 5, ""), tblStr(t, "offset", 6, ""), tblInt(t, "dir", 7, 0), tblNum(t, "sim", 8, 0.9))
                return LuaValue.varargsOf(LuaValue.valueOf(x), LuaValue.valueOf(y))
            }
        })
        g.set("findMultiColorAll", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                args.optint(7, 0)   // dir 对 All 变体只影响返回点序，收下忽略（对齐 iOS）
                return LuaValue.valueOf(ColorFind.findMultiColorAll(
                    args.optint(1, 0), args.optint(2, 0), args.optint(3, 0), args.optint(4, 0),
                    args.checkjstring(5), args.optjstring(6, ""), args.optdouble(8, 0.9)))
            }
        })
        g.set("findMultiColorAllT", object : OneArgFunction() {
            override fun call(t: LuaValue): LuaValue {
                t.checktable()
                return LuaValue.valueOf(ColorFind.findMultiColorAll(
                    tblInt(t, "x1", 1, 0), tblInt(t, "y1", 2, 0), tblInt(t, "x2", 3, 0), tblInt(t, "y2", 4, 0),
                    tblStr(t, "color", 5, ""), tblStr(t, "offset", 6, ""), tblNum(t, "sim", 7, 0.9)))
            }
        })
        g.set("cmpColor", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                return LuaValue.valueOf(ColorFind.cmpColor(
                    args.checkint(1), args.checkint(2), args.checkjstring(3), args.optdouble(4, 0.9)))
            }
        })
        g.set("cmpColorEx", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                return LuaValue.valueOf(ColorFind.cmpColorEx(args.checkjstring(1), args.optdouble(2, 0.9)))
            }
        })
        g.set("cmpColorExT", object : OneArgFunction() {
            override fun call(t: LuaValue): LuaValue {
                t.checktable()
                // spec 串（具名 spec / 数组[1]字符串）或 x+y+color 拼接（对齐 iOS）
                var spec = tblGet(t, "spec", 0)
                if (!spec.isstring()) spec = t.get(1)
                if (!spec.isstring()) {
                    spec = LuaValue.valueOf(
                        tblStr(t, "x", 1, "0") + "|" + tblStr(t, "y", 2, "0") + "|" + tblStr(t, "color", 3, ""))
                }
                return LuaValue.valueOf(ColorFind.cmpColorEx(spec.checkjstring(), tblNum(t, "sim", 0, 0.9)))
            }
        })
        g.set("getColorNum", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                return LuaValue.valueOf(ColorFind.getColorNum(
                    args.optint(1, 0), args.optint(2, 0), args.optint(3, 0), args.optint(4, 0),
                    args.checkjstring(5), args.optdouble(6, 0.9)))
            }
        })
        g.set("colorDiff", object : TwoArgFunction() {
            override fun call(c1: LuaValue, c2: LuaValue): LuaValue =
                LuaValue.valueOf(ColorFind.colorDiff(c1.checkjstring(), c2.checkjstring()))
        })
        g.set("colorToRGB", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val cv = args.arg1()
                var v = if (cv.isnumber()) cv.checklong() else (cv.checkjstring().removePrefix("0x").toLongOrNull(16) ?: 0L)
                v = v and 0xFFFFFF
                return LuaValue.varargsOf(LuaValue.valueOf((v and 0xFF).toInt()),
                    LuaValue.varargsOf(LuaValue.valueOf(((v shr 8) and 0xFF).toInt()),
                        LuaValue.valueOf(((v shr 16) and 0xFF).toInt())))
            }
        })
        g.set("getScreenPixel", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val arr = ColorFind.getScreenPixel(
                    args.optint(1, 0), args.optint(2, 0), args.optint(3, 0), args.optint(4, 0))
                    ?: return NIL
                val t = LuaValue.tableOf()
                for (i in arr.indices) t.set(i + 1, LuaValue.valueOf(arr[i]))
                return t
            }
        })
        g.set("isDisplayDead", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                return LuaValue.valueOf(ColorFind.isDisplayDead(
                    args.optint(1, 0), args.optint(2, 0), args.optint(3, 0), args.optint(4, 0),
                    args.optdouble(5, 5.0)))
            }
        })
        // 截图缓存/分辨率缩放：设备端天然满足（对齐 iOS noop true）
        g.set("keepCapture", object : ZeroArg() { override fun call0(): LuaValue = TRUE })
        g.set("releaseCapture", object : ZeroArg() { override fun call0(): LuaValue = TRUE })
        g.set("setScreenScale", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs = TRUE
        })
        g.set("snapShot", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val path = args.checkjstring(1)
                val f = ProjectionService.latestFrame() ?: return NIL
                return try {
                    java.io.FileOutputStream(path).use { fout ->
                        f.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, fout)
                    }
                    LuaValue.valueOf(path)
                } catch (e: Exception) { NIL }
            }
        })
        // ---------------- 找图（PicFind：SAD 粗筛+精修，findPicEx 走 alpha 遮罩） ----------------
        val findPicFn = object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val (x, y) = PicFind.findPic(
                    args.optint(1, 0), args.optint(2, 0), args.optint(3, 0), args.optint(4, 0),
                    args.checkjstring(5), args.optdouble(6, 0.9), false)
                return LuaValue.varargsOf(LuaValue.valueOf(x), LuaValue.valueOf(y))
            }
        }
        val findPicExFn = object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val (x, y) = PicFind.findPic(
                    args.optint(1, 0), args.optint(2, 0), args.optint(3, 0), args.optint(4, 0),
                    args.checkjstring(5), args.optdouble(6, 0.9), true)
                return LuaValue.varargsOf(LuaValue.valueOf(x), LuaValue.valueOf(y))
            }
        }
        g.set("findPic", findPicFn)
        g.set("findPicFast", findPicFn)   // 别名（对齐 iOS）
        g.set("findImage", findPicFn)
        g.set("findPicEx", findPicExFn)
        g.set("findPicAllPoint", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val pts = PicFind.findAllPoint(
                    args.optint(1, 0), args.optint(2, 0), args.optint(3, 0), args.optint(4, 0),
                    args.checkjstring(5), args.optdouble(6, 0.9), args.optint(7, 0))
                if (pts.isEmpty()) return NIL
                val t = LuaValue.tableOf()
                for ((i, p) in pts.withIndex()) {
                    val e = LuaValue.tableOf()
                    e.set(1, LuaValue.valueOf(p.first))
                    e.set(2, LuaValue.valueOf(p.second))
                    t.set(i + 1, e)
                }
                return t
            }
        })
        g.set("findCircle", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val (cx, cy, r) = PicFind.findCircle(
                    args.optint(1, 0), args.optint(2, 0), args.optint(3, 0), args.optint(4, 0),
                    args.optint(5, 1), args.optint(6, 20), args.optint(7, 100),
                    args.optint(8, 30), args.optint(9, 5), args.optint(10, 200))
                return LuaValue.varargsOf(LuaValue.valueOf(cx),
                    LuaValue.varargsOf(LuaValue.valueOf(cy), LuaValue.valueOf(r)))
            }
        })
        // ---------------- OCR（PP-OCRv6，模型放 <externalFiles>/ocr/ 懒加载，同 iOS 分发策略） ----------------
        g.set("ocrText", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val items = OcrEngine.region(ctx,
                    args.optint(1, 0), args.optint(2, 0), args.optint(3, 0), args.optint(4, 0))
                return LuaValue.valueOf(items.joinToString("\n") { it.text })
            }
        })
        g.set("ocrTextEx", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val items = OcrEngine.region(ctx,
                    args.optint(1, 0), args.optint(2, 0), args.optint(3, 0), args.optint(4, 0))
                val t = LuaValue.tableOf()
                for ((i, it) in items.withIndex()) {
                    val row = LuaValue.tableOf()
                    row.set("text", LuaValue.valueOf(it.text))
                    row.set("x", LuaValue.valueOf(it.x))
                    row.set("y", LuaValue.valueOf(it.y))
                    row.set("w", LuaValue.valueOf(it.w))
                    row.set("h", LuaValue.valueOf(it.h))
                    row.set("score", LuaValue.valueOf(it.score.toDouble()))
                    t.set(i + 1, row)
                }
                return t
            }
        })
        g.set("findStr", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val needle = args.checkjstring(5)
                val items = OcrEngine.region(ctx,
                    args.optint(1, 0), args.optint(2, 0), args.optint(3, 0), args.optint(4, 0))
                for (it in items) {
                    if (it.text.contains(needle)) {
                        return LuaValue.varargsOf(LuaValue.valueOf(it.x + it.w / 2), LuaValue.valueOf(it.y + it.h / 2))
                    }
                }
                return LuaValue.varargsOf(LuaValue.valueOf(-1), LuaValue.valueOf(-1))
            }
        })
        // ---------------- 休眠（切片 50ms 可中断） ----------------
        g.set("sleep", object : OneArgFunction() {
            override fun call(s: LuaValue): LuaValue {
                var left = (s.checkdouble() * 1000).toLong()
                while (left > 0) {
                    if (checkStop()) throw LuaError("__MATISU_STOP__")
                    val step = if (left > 50) 50 else left
                    Thread.sleep(step)
                    left -= step
                }
                if (checkStop()) throw LuaError("__MATISU_STOP__")
                return NIL
            }
        })
        g.set("mSleep", object : OneArgFunction() {
            override fun call(ms: LuaValue): LuaValue {
                var left = ms.checklong()
                while (left > 0) {
                    if (checkStop()) throw LuaError("__MATISU_STOP__")
                    val step = if (left > 50) 50 else left
                    Thread.sleep(step)
                    left -= step
                }
                if (checkStop()) throw LuaError("__MATISU_STOP__")
                return NIL
            }
        })
        // ---------------- 设备信息 ----------------
        g.set("getCpuArch", object : ZeroArg() {
            override fun call0(): LuaValue = LuaValue.valueOf(Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown")
        })
        g.set("getDisplayDpi", object : ZeroArg() {
            override fun call0(): LuaValue = LuaValue.valueOf(c?.resources?.configuration?.densityDpi ?: 160)
        })
        g.set("getBatteryLevel", object : ZeroArg() {
            override fun call0(): LuaValue {
                val bm = c?.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
                val v = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
                return LuaValue.valueOf(v)
            }
        })
        g.set("isCharging", object : ZeroArg() {
            override fun call0(): LuaValue {
                val it = c?.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                val st = it?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
                return LuaValue.valueOf(st == BatteryManager.BATTERY_STATUS_CHARGING || st == BatteryManager.BATTERY_STATUS_FULL)
            }
        })
        g.set("getDeviceId", object : ZeroArg() {
            override fun call0(): LuaValue =
                LuaValue.valueOf(android.provider.Settings.Secure.getString(c?.contentResolver, android.provider.Settings.Secure.ANDROID_ID) ?: "")
        })
        g.set("getModel", object : ZeroArg() { override fun call0(): LuaValue = LuaValue.valueOf(Build.MODEL ?: "") })
        g.set("getDeviceName", object : ZeroArg() {
            override fun call0(): LuaValue =
                LuaValue.valueOf(android.provider.Settings.Global.getString(c?.contentResolver, "device_name") ?: Build.MODEL ?: "")
        })
        g.set("getSysVer", object : ZeroArg() { override fun call0(): LuaValue = LuaValue.valueOf(Build.VERSION.RELEASE ?: "") })
        g.set("getOsVersionName", object : ZeroArg() { override fun call0(): LuaValue = LuaValue.valueOf(Build.VERSION.RELEASE ?: "") })
        g.set("getScreenDirection", object : ZeroArg() {
            override fun call0(): LuaValue {
                val o = c?.resources?.configuration?.orientation ?: 1
                return LuaValue.valueOf(if (o == 2) "landscape" else "portrait")
            }
        })
        g.set("getSysLang", object : ZeroArg() {
            override fun call0(): LuaValue = LuaValue.valueOf(java.util.Locale.getDefault().toString())
        })
        g.set("getSysTimezone", object : ZeroArg() {
            override fun call0(): LuaValue = LuaValue.valueOf(java.util.TimeZone.getDefault().id)
        })
        g.set("getDeviceType", object : ZeroArg() { override fun call0(): LuaValue = LuaValue.valueOf("android") })
        g.set("getEngineVersion", object : ZeroArg() { override fun call0(): LuaValue = LuaValue.valueOf(ENGINE_VERSION) })
        g.set("getScreenResolution", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val f = ProjectionService.latestFrame()
                if (f != null) return LuaValue.varargsOf(LuaValue.valueOf(f.width), LuaValue.valueOf(f.height))
                val (w, h) = AutoAccessibilityService.displaySize()
                return LuaValue.varargsOf(LuaValue.valueOf(w), LuaValue.valueOf(h))
            }
        })
        g.set("getScreenFrame", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val f = ProjectionService.latestFrame()
                val w = f?.width ?: AutoAccessibilityService.displaySize().first
                val h = f?.height ?: AutoAccessibilityService.displaySize().second
                return LuaValue.varargsOf(LuaValue.valueOf(0),
                    LuaValue.varargsOf(LuaValue.valueOf(0),
                        LuaValue.varargsOf(LuaValue.valueOf(w), LuaValue.valueOf(h))))
            }
        })
        g.set("frontAppName", object : ZeroArg() {
            override fun call0(): LuaValue = LuaValue.valueOf(svc?.rootInActiveWindow?.packageName?.toString() ?: "")
        })
        // ---------------- 应用管理 ----------------
        g.set("runApp", object : OneArgFunction() {
            override fun call(pkg: LuaValue): LuaValue {
                val cc = c ?: return FALSE
                val intent = cc.packageManager.getLaunchIntentForPackage(pkg.checkjstring()) ?: return FALSE
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                return try { cc.startActivity(intent); TRUE } catch (e: Exception) { FALSE }
            }
        })
        g.set("stopApp", object : OneArgFunction() {
            override fun call(pkg: LuaValue): LuaValue {
                val cc = c ?: return FALSE
                return try {
                    val am = cc.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
                    am.killBackgroundProcesses(pkg.checkjstring())
                    TRUE
                } catch (e: Exception) { FALSE }
            }
        })
        g.set("appIsRunning", object : OneArgFunction() {
            override fun call(pkg: LuaValue): LuaValue {
                val cc = c ?: return FALSE
                return try {
                    cc.packageManager.getPackageInfo(pkg.checkjstring(), 0)
                    TRUE
                } catch (e: Exception) { FALSE }
            }
        })
        g.set("openUrl", object : OneArgFunction() {
            override fun call(url: LuaValue): LuaValue {
                val cc = c ?: return FALSE
                return try {
                    val i = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url.checkjstring()))
                    i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    cc.startActivity(i)
                    TRUE
                } catch (e: Exception) { FALSE }
            }
        })
        g.set("readPasteboard", object : ZeroArg() {
            override fun call0(): LuaValue {
                val cm = c?.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                return LuaValue.valueOf(cm?.primaryClip?.getItemAt(0)?.text?.toString() ?: "")
            }
        })
        g.set("writePasteboard", object : OneArgFunction() {
            override fun call(text: LuaValue): LuaValue {
                val cm = c?.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return FALSE
                cm.setPrimaryClip(ClipData.newPlainText("matisu", text.checkjstring()))
                return TRUE
            }
        })
        // ---------------- 系统控制 ----------------
        g.set("rnd", object : TwoArgFunction() {
            override fun call(a: LuaValue, b: LuaValue): LuaValue {
                var lo = a.checkint(); var hi = b.checkint()
                if (lo > hi) { val t2 = lo; lo = hi; hi = t2 }
                return LuaValue.valueOf(lo + java.util.Random().nextInt(hi - lo + 1))
            }
        })
        g.set("vibrate", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val v = c?.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
                return if (v != null) {
                    @Suppress("DEPRECATION") v.vibrate(500)
                    TRUE
                } else FALSE
            }
        })
        g.set("restartScript", object : ZeroArg() {
            override fun call0(): LuaValue = throw LuaError("__MATISU_RESTART__")
        })
        g.set("exitScript", object : ZeroArg() {
            override fun call0(): LuaValue = throw LuaError("__MATISU_EXIT__")
        })
        g.set("setStopCallBack", object : OneArgFunction() {
            override fun call(fn: LuaValue): LuaValue {
                fn.checkfunction()
                stopCb = fn
                return NIL
            }
        })
        g.set("lockScreen", object : ZeroArg() {
            override fun call0(): LuaValue { EngineLog.append("[WARN] lockScreen: Android 端暂未实现\n"); return FALSE }
        })
        g.set("unLockScreen", object : ZeroArg() {
            override fun call0(): LuaValue { EngineLog.append("[WARN] unLockScreen: Android 端暂未实现\n"); return FALSE }
        })
        // ---------------- 日志控制台 ----------------
        g.set("logPrint", logf("INFO"))
        g.set("logDebug", logf("DEBUG"))
        g.set("logInfo", logf("INFO"))
        g.set("logWarn", logf("WARN"))
        g.set("logError", logf("ERROR"))
        g.set("vvLog", logf("TRACE"))
        g.set("clearCLog", object : ZeroArg() {
            override fun call0(): LuaValue {
                EngineLog.logFile?.let { try { it.writeText("") } catch (_: Exception) {} }
                return NIL
            }
        })
        // ---------------- 网络（network 表 + 全局别名） ----------------
        val httpGetFn = object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val (d, code) = http("GET", args.checkjstring(1), null, args.optdouble(2, 30.0))
                if (d == null) return LuaValue.varargsOf(NIL, LuaValue.valueOf(0))
                return LuaValue.varargsOf(LuaString.valueOf(d), LuaValue.valueOf(code))
            }
        }
        val httpPostFn = object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val body = if (args.isstring(2) || args.isnumber(2)) args.checkjstring(2).toByteArray(Charsets.UTF_8) else ByteArray(0)
                val (d, code) = http("POST", args.checkjstring(1), body, args.optdouble(3, 30.0))
                if (d == null) return LuaValue.varargsOf(NIL, LuaValue.valueOf(0))
                return LuaValue.varargsOf(LuaString.valueOf(d), LuaValue.valueOf(code))
            }
        }
        val downloadFn = object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val (d, _) = http("GET", args.checkjstring(1), null, args.optdouble(3, 60.0))
                if (d == null) return FALSE
                return try {
                    java.io.FileOutputStream(args.checkjstring(2)).use { it.write(d) }
                    TRUE
                } catch (e: Exception) { FALSE }
            }
        }
        g.set("httpGet", httpGetFn)
        g.set("httpPost", httpPostFn)
        g.set("downloadFile", downloadFn)
        val network = LuaValue.tableOf()
        network.set("httpGet", httpGetFn)
        network.set("httpPost", httpPostFn)
        network.set("download", downloadFn)
        g.set("network", network)
        // ---------------- 加解密与编码（cipher 表 + 全局别名） ----------------
        val md5Fn = object : OneArgFunction() {
            override fun call(s: LuaValue): LuaValue = LuaValue.valueOf(digestHex("MD5", s.checkjstring().toByteArray(Charsets.UTF_8)))
        }
        val sha1Fn = object : OneArgFunction() {
            override fun call(s: LuaValue): LuaValue = LuaValue.valueOf(digestHex("SHA-1", s.checkjstring().toByteArray(Charsets.UTF_8)))
        }
        val b64encFn = object : OneArgFunction() {
            override fun call(s: LuaValue): LuaValue =
                LuaValue.valueOf(android.util.Base64.encodeToString(s.checkjstring().toByteArray(Charsets.UTF_8), android.util.Base64.NO_WRAP))
        }
        val b64decFn = object : OneArgFunction() {
            override fun call(s: LuaValue): LuaValue {
                val d = try { android.util.Base64.decode(s.checkjstring(), android.util.Base64.DEFAULT) } catch (e: Exception) { return NIL }
                return LuaString.valueOf(d)
            }
        }
        g.set("MD5", md5Fn)
        g.set("sha1", sha1Fn)
        g.set("encodeBase64", b64encFn)
        g.set("decodeBase64", b64decFn)
        val cipher = LuaValue.tableOf()
        cipher.set("md5", md5Fn)
        cipher.set("sha1", sha1Fn)
        cipher.set("base64", b64encFn)
        g.set("cipher", cipher)
        // ---------------- JSON（jsonLib 表，json 为别名） ----------------
        val jsonEncFn = object : OneArgFunction() {
            override fun call(v: LuaValue): LuaValue {
                val sb = StringBuilder()
                jsonEnc(v, sb)
                return LuaValue.valueOf(sb.toString())
            }
        }
        val jsonDecFn = object : OneArgFunction() {
            override fun call(s: LuaValue): LuaValue {
                return try {
                    val v = org.json.JSONTokener(s.checkjstring()).nextValue()
                    jsonDec(v)
                } catch (e: Exception) {
                    // 对齐 iOS/cjson：解析失败抛错
                    throw LuaError("json.decode: ${e.message}")
                }
            }
        }
        val jsonLib = LuaValue.tableOf()
        jsonLib.set("encode", jsonEncFn)
        jsonLib.set("decode", jsonDecFn)
        g.set("jsonLib", jsonLib)
        g.set("json", jsonLib)
        // ---------------- 字符串处理（strutils：两端同源 Lua 实现） ----------------
        try { g.load(STRUTILS_LUA.trimIndent(), "=strutils").call() } catch (_: Throwable) {}
    }

    /** ZeroArg 便捷基类 */
    private abstract class ZeroArg : org.luaj.vm2.lib.ZeroArgFunction() {
        abstract fun call0(): LuaValue
        override fun call(): LuaValue = call0()
    }

    private fun digestHex(algo: String, data: ByteArray): String =
        java.security.MessageDigest.getInstance(algo).digest(data).joinToString("") { String.format("%02x", it) }

    private fun http(method: String, urlStr: String, body: ByteArray?, timeoutS: Double): Pair<ByteArray?, Int> {
        return try {
            val conn = URL(urlStr).openConnection() as HttpURLConnection
            conn.requestMethod = method
            conn.connectTimeout = (timeoutS * 1000).toInt().coerceIn(1000, 300000)
            conn.readTimeout = (timeoutS * 1000).toInt().coerceIn(1000, 300000)
            if (method == "POST") {
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
            }
            if (body != null && method == "POST") conn.outputStream.use { it.write(body) }
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            Pair(stream?.readBytes(), code)
        } catch (e: Exception) { Pair(null, 0) }
    }

    // ---------------- JSON 编解码（空表编 {} 对齐 iOS/cjson 语义） ----------------
    private fun jsonEnc(v: LuaValue, sb: StringBuilder) {
        when {
            v.isnil() -> sb.append("null")
            v.isboolean() -> sb.append(if (v.toboolean()) "true" else "false")
            v.isnumber() -> {
                val d = v.todouble()
                if (d == kotlin.math.floor(d) && !d.isInfinite() && kotlin.math.abs(d) < 1e15) sb.append(d.toLong().toString())
                else sb.append(d.toString())
            }
            v.isstring() -> sb.append(org.json.JSONObject.quote(v.tojstring()))
            v.istable() -> {
                val t = v.checktable()
                // 数组判定：1..n 连续且无其他键
                var n = 0
                while (!t.get(n + 1).isnil()) n++
                var cnt = 0; var extra = false
                var k: LuaValue = LuaValue.NIL
                while (true) {
                    val nv: Varargs = t.next(k)
                    k = nv.arg1()
                    if (k.isnil()) break
                    cnt++
                    val ki = if (k.isnumber()) k.toint() else -1
                    if (ki < 1 || ki > n) { extra = true; break }
                }
                if (cnt == 0 && n == 0) { sb.append("{}"); return }   // 空表 -> {}（对象）
                if (n > 0 && !extra && cnt == n) {
                    sb.append('[')
                    for (i in 1..n) { if (i > 1) sb.append(','); jsonEnc(t.get(i), sb) }
                    sb.append(']')
                } else {
                    sb.append('{')
                    var first = true
                    var k2: LuaValue = LuaValue.NIL
                    while (true) {
                        val nv: Varargs = t.next(k2)
                        k2 = nv.arg1()
                        if (k2.isnil()) break
                        if (!first) sb.append(',')
                        first = false
                        sb.append(org.json.JSONObject.quote(k2.tojstring())).append(':')
                        jsonEnc(nv.arg(2), sb)
                    }
                    sb.append('}')
                }
            }
            else -> sb.append(org.json.JSONObject.quote(v.tojstring()))
        }
    }

    private fun jsonDec(v: Any?): LuaValue = when {
        v == null || v == org.json.JSONObject.NULL -> LuaValue.NIL
        v is org.json.JSONObject -> {
            val t = LuaValue.tableOf()
            val it = v.keys()
            while (it.hasNext()) {
                val key = it.next()
                t.set(key, jsonDec(v.opt(key)))
            }
            t
        }
        v is org.json.JSONArray -> {
            val t = LuaValue.tableOf()
            for (i in 0 until v.length()) t.set(i + 1, jsonDec(v.get(i)))
            t
        }
        v is Boolean -> LuaValue.valueOf(v)
        v is Int -> LuaValue.valueOf(v)
        v is Long -> LuaValue.valueOf(v.toDouble())
        v is Double -> LuaValue.valueOf(v)
        v is Float -> LuaValue.valueOf(v.toDouble())
        v is Number -> LuaValue.valueOf(v.toDouble())
        v is String -> LuaValue.valueOf(v)
        else -> LuaValue.valueOf(v.toString())
    }

    // ---------------- strutils：两端同源 Lua 实现（iOS 端注册同一份源码） ----------------
    private const val STRUTILS_LUA = """
        strutils = {}
        function strutils.bin2Hex(data, ishex)
          data = tostring(data or "")
          local parts = {}
          for i = 1, #data do
            local b = string.byte(data, i)
            if ishex then parts[i] = string.format("%02x", b)
            else parts[i] = tostring(b) end
          end
          return table.concat(parts, ishex and "" or " ")
        end
        function strutils.split(str, delimiter, limit)
          str = tostring(str or "")
          delimiter = delimiter == nil and " " or tostring(delimiter)
          limit = tonumber(limit) or 0
          local out = {}
          if delimiter == "" then
            for i = 1, #str do out[i] = string.sub(str, i, i) end
            return out
          end
          local pos = 1
          while true do
            if limit > 0 and #out >= limit then break end
            local s, e = string.find(str, delimiter, pos, true)
            if not s then break end
            out[#out + 1] = string.sub(str, pos, s - 1)
            pos = e + 1
          end
          out[#out + 1] = string.sub(str, pos)
          return out
        end
        function strutils.trim(s)
          return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
        end
        function strutils.replace(s, a, b)
          s = tostring(s or ""); a = tostring(a or ""); b = tostring(b or "")
          if a == "" then return s end
          local out, pos = {}, 1
          while true do
            local i, j = string.find(s, a, pos, true)
            if not i then break end
            out[#out + 1] = string.sub(s, pos, i - 1) .. b
            pos = j + 1
          end
          out[#out + 1] = string.sub(s, pos)
          return table.concat(out)
        end
        function strutils.startswith(s, p)
          s = tostring(s or ""); p = tostring(p or "")
          return string.sub(s, 1, #p) == p
        end
        function strutils.endswith(s, p)
          s = tostring(s or ""); p = tostring(p or "")
          if p == "" then return true end
          return string.sub(s, -#p) == p
        end
        function strutils.upper(s) return string.upper(tostring(s or "")) end
        function strutils.lower(s) return string.lower(tostring(s or "")) end
    """

    /** print 包装：加 [chunk:line] 定位前缀（依赖 debug 库；iOS 端由 luaL_where 原生实现） */
    private const val PRINT_WRAP = """
        local _p = print
        local _gi = debug and debug.getinfo or nil
        print = function(...)
          local loc = ""
          if _gi then
            local ok, info = pcall(_gi, 2, "Sl")
            if ok and info and info.currentline and info.currentline > 0 then
              loc = "[" .. tostring(info.short_src or "?") .. ":" .. tostring(info.currentline) .. "] "
            end
          end
          local n = select("#", ...)
          local parts = {}
          for i = 1, n do parts[i] = tostring(select(i, ...)) end
          _p(loc .. table.concat(parts, "\t"))
        end
    """

    private fun wrapPrintLoc(g: Globals) {
        try { g.load(PRINT_WRAP.trimIndent(), "=printwrap").call() } catch (_: Throwable) {}
    }

    private fun invokeStopCb(g: Globals) {
        val cb = stopCb ?: return
        try { cb.call() } catch (_: Throwable) {}
    }

    // ---------------- one-shot（支持 restartScript 循环重跑） ----------------
    fun run(source: String, chunk: String = "script"): RunResult {
        var restarts = 0
        while (true) {
            val out = StringBuilder()
            val g = JsePlatform.debugGlobals()
            runStop = false
            var doRestart = false
            val result: RunResult = try {
                registerFns(g, out) { svcStop || runStop }
                wrapPrintLoc(g)
                g.load(source, chunk).call()
                RunResult(true, out.toString(), globals = dumpGlobals(g))
            } catch (e: LuaError) {
                val msg = e.message ?: ""
                when {
                    msg.contains("__MATISU_STOP__") -> {
                        invokeStopCb(g)
                        RunResult(true, out.toString(), globals = dumpGlobals(g), stopped = true)
                    }
                    msg.contains("__MATISU_RESTART__") && restarts < 16 -> { doRestart = true; RunResult(true, out.toString()) }
                    msg.contains("__MATISU_EXIT__") ->
                        RunResult(true, out.toString(), globals = dumpGlobals(g), stopped = true)
                    else -> RunResult(false, out.toString(), msg.ifEmpty { e.toString() }, globals = dumpGlobals(g))
                }
            } catch (e: Throwable) {
                RunResult(false, out.toString(), e.message ?: e.toString(), globals = dumpGlobals(g))
            }
            if (doRestart) { restarts++; continue }
            return result
        }
    }

    // ---------------- 全局变量快照（调试面板变量表） ----------------
    // 遍历全局表，过滤标准库符号；table/function 不展开，值截断 120 字符。返回 JSON 数组文本。
    private val G_SKIP = setOf(
        "_G", "_VERSION", "assert", "collectgarbage", "dofile", "error", "getfenv",
        "getmetatable", "ipairs", "load", "loadfile", "loadstring", "next", "pairs",
        "pcall", "print", "rawequal", "rawget", "rawset", "require", "select",
        "setfenv", "setmetatable", "tonumber", "tostring", "type", "unpack",
        "xpcall", "string", "table", "math", "os", "io", "debug", "coroutine",
        "package", "exitScript", "sleep", "init"
    )

    private fun dumpGlobals(g: Globals): String {
        val sb = StringBuilder("[")
        var n = 0
        try {
            // lua_next 语义遍历（next 返回 varargs: key, value）
            var k: LuaValue = LuaValue.NIL
            while (n < 100) {
                val nv: Varargs = g.next(k)
                k = nv.arg1()
                if (k.isnil()) break
                if (!k.isstring()) continue
                val name = k.tojstring()
                if (name in G_SKIP) continue
                val v = nv.arg(2)
                val vt = v.typename()
                val sv = when {
                    v.istable() -> "<table>"
                    v.isfunction() -> "<function>"
                    else -> {
                        val s = v.tojstring()
                        if (s.length > 120) s.substring(0, 120) + "…" else s
                    }
                }
                if (n > 0) sb.append(',')
                sb.append('[')
                    .append(org.json.JSONObject.quote(name)).append(',')
                    .append(org.json.JSONObject.quote(sv)).append(',')
                    .append(org.json.JSONObject.quote(vt))
                    .append(']')
                n++
            }
        } catch (_: Throwable) {}
        sb.append(']')
        return sb.toString()
    }

    // ---------------- 常驻（支持 restartScript 重启） ----------------
    @Synchronized
    fun start(source: String): Boolean {
        if (svcRunning) return false
        svcStop = false
        svcRunning = true
        svcSource = source
        svcThread = Thread {
            val out = svcOut
            var restarts = 0
            while (true) {
                try {
                    val g = JsePlatform.debugGlobals()
                    registerFns(g, out) { svcStop }
                    wrapPrintLoc(g)
                    g.load(source, "service").call()
                } catch (e: Throwable) {
                    val msg = e.message ?: ""
                    if (msg.contains("__MATISU_RESTART__") && restarts < 16 && !svcStop) { restarts++; continue }
                    if (!msg.contains("__MATISU_STOP__") && !msg.contains("__MATISU_EXIT__")) {
                        synchronized(outLock) { svcOut.append("[service error] $msg\n") }
                        EngineLog.append("[service error] $msg\n")
                    }
                }
                break
            }
            svcRunning = false
            svcThread = null
        }.also { it.isDaemon = true; it.start() }
        return true
    }

    @Synchronized
    fun stop() {
        if (svcRunning) svcStop = true
        runStop = true   // one-shot(F5)：sleep 切片下一拍中断
    }

    fun drainOutput(): String = synchronized(outLock) {
        val r = svcOut.toString()
        svcOut.setLength(0)
        r
    }

    // ---------------- 自启动 ----------------
    fun autoRun() {
        val f = File(scriptDir ?: return, "autorun.lua")
        if (f.isFile) start(f.readText())
    }
}
