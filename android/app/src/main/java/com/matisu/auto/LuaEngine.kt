package com.matisu.auto

import org.luaj.vm2.Globals
import org.luaj.vm2.LuaError
import org.luaj.vm2.LuaValue
import org.luaj.vm2.Varargs
import org.luaj.vm2.lib.OneArgFunction
import org.luaj.vm2.lib.TwoArgFunction
import org.luaj.vm2.lib.VarArgFunction
import org.luaj.vm2.lib.jse.JsePlatform
import java.io.File

/**
 * MatisuAuto Android 设备端 Lua 引擎（LuaJ）
 * 与 iOS 设备端引擎同契约：print/tap/swipe/touchDown/Move/Up/keyPress/
 * inputText/getDisplaySize/sleep/mSleep + 脚本管理（run/start/stop/state）。
 *
 * 常驻脚本中断：stop 置标志位，mSleep/sleep 下一拍抛 LuaError（原版脚本
 * 循环必带 sleep 的惯例下延迟可控）。
 */
object LuaEngine {

    data class RunResult(val ok: Boolean, val output: String, val error: String? = null)

    private var svcThread: Thread? = null
    @Volatile private var svcStop = false
    @Volatile var svcRunning = false
        private set
    private val svcOut = StringBuilder()
    private val outLock = Any()

    /** 脚本目录（app 私有可写） */
    var scriptDir: File? = null

    // ---------------- 函数注册 ----------------
    private fun registerFns(g: Globals, out: StringBuilder, checkStop: () -> Boolean) {
        val svc = AutoAccessibilityService.instance

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
        g.set("inputText", object : OneArgFunction() {
            override fun call(text: LuaValue): LuaValue {
                svc?.inputText(text.checkjstring())
                return LuaValue.valueOf(svc != null)
            }
        })
        g.set("getDisplaySize", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val (w, h) = AutoAccessibilityService.displaySize()
                return LuaValue.varargsOf(LuaValue.valueOf(w), LuaValue.valueOf(h))
            }
        })
        // ---------------- 图色系（帧源 ProjectionService） ----------------
        g.set("getPixelColor", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val c = ColorFind.getPixel(args.checkint(1), args.checkint(2))
                if (c < 0) return NIL
                val type = if (args.narg() >= 3) args.checkint(3) else 0
                return if (type == 1) LuaValue.valueOf(c)
                else LuaValue.valueOf(String.format("%06X", c and 0xFFFFFF))
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
        g.set("getColorNum", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                return LuaValue.valueOf(ColorFind.getColorNum(
                    args.optint(1, 0), args.optint(2, 0), args.optint(3, 0), args.optint(4, 0),
                    args.checkjstring(5), args.optdouble(6, 0.9)))
            }
        })
        g.set("snapShot", object : VarArgFunction() {
            override fun invoke(args: Varargs): Varargs {
                val path = args.checkjstring(1)
                val f = ProjectionService.latestFrame() ?: return NIL
                return try {
                    java.io.FileOutputStream(path).use { out ->
                        f.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)
                    }
                    LuaValue.valueOf(path)
                } catch (e: Exception) { NIL }
            }
        })
        g.set("sleep", object : OneArgFunction() {
            override fun call(s: LuaValue): LuaValue {
                Thread.sleep((s.checkdouble() * 1000).toLong())
                if (checkStop()) throw LuaError("__MATISU_STOP__")
                return NIL
            }
        })
        g.set("mSleep", object : OneArgFunction() {
            override fun call(ms: LuaValue): LuaValue {
                Thread.sleep(ms.checklong())
                if (checkStop()) throw LuaError("__MATISU_STOP__")
                return NIL
            }
        })
    }

    // ---------------- one-shot ----------------
    fun run(source: String): RunResult {
        val out = StringBuilder()
        return try {
            val g = JsePlatform.standardGlobals()
            registerFns(g, out) { false }
            g.load(source, "script").call()
            RunResult(true, out.toString())
        } catch (e: Throwable) {
            RunResult(false, out.toString(), e.message ?: e.toString())
        }
    }

    // ---------------- 常驻 ----------------
    @Synchronized
    fun start(source: String): Boolean {
        if (svcRunning) return false
        svcStop = false
        svcRunning = true
        svcThread = Thread {
            val out = svcOut
            try {
                val g = JsePlatform.standardGlobals()
                registerFns(g, out) { svcStop }
                g.load(source, "service").call()
            } catch (e: Throwable) {
                val msg = e.message ?: ""
                if (!msg.contains("__MATISU_STOP__")) {
                    synchronized(outLock) { svcOut.append("[service error] $msg\n") }
                    EngineLog.append("[service error] $msg\n")
                }
            } finally {
                svcRunning = false
                svcThread = null
            }
        }.also { it.isDaemon = true; it.start() }
        return true
    }

    @Synchronized
    fun stop() {
        if (svcRunning) svcStop = true
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
