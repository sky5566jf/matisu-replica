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

    data class RunResult(val ok: Boolean, val output: String, val error: String? = null, val globals: String? = null, val stopped: Boolean = false)

    private var svcThread: Thread? = null
    @Volatile var svcStop = false
    @Volatile var runStop = false   // one-shot(F5) 停止标志（ScriptServer stop 命令置位）
    @Volatile var svcRunning = false
        private set
    private val svcOut = StringBuilder()
    private val outLock = Any()

    /** 脚本目录（app 私有可写） */
    var scriptDir: File? = null

    // ---------------- 函数注册 ----------------
    private fun registerFns(g: Globals, out: StringBuilder, checkStop: () -> Boolean) {        val svc = AutoAccessibilityService.instance

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
    }

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

    // ---------------- one-shot ----------------
    fun run(source: String, chunk: String = "script"): RunResult {
        val out = StringBuilder()
        val g = JsePlatform.debugGlobals()
        runStop = false
        return try {
            registerFns(g, out) { svcStop || runStop }
            wrapPrintLoc(g)
            g.load(source, chunk).call()
            RunResult(true, out.toString(), globals = dumpGlobals(g))
        } catch (e: LuaError) {
            if ((e.message ?: "").contains("__MATISU_STOP__"))
                RunResult(true, out.toString(), globals = dumpGlobals(g), stopped = true)
            else RunResult(false, out.toString(), e.message ?: e.toString(), globals = dumpGlobals(g))
        } catch (e: Throwable) {
            RunResult(false, out.toString(), e.message ?: e.toString(), globals = dumpGlobals(g))
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

    // ---------------- 常驻 ----------------
    @Synchronized
    fun start(source: String): Boolean {
        if (svcRunning) return false
        svcStop = false
        svcRunning = true
        svcThread = Thread {
            val out = svcOut
            try {
                val g = JsePlatform.debugGlobals()
                registerFns(g, out) { svcStop }
                wrapPrintLoc(g)
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
