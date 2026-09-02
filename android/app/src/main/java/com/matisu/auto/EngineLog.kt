package com.matisu.auto

import android.content.Context
import java.io.File

/** 统一目录约定（与 iOS 数据区对齐：scripts=工作目录、logs=日志目录） */
object MatisuDirs {
    fun scripts(ctx: Context): File =
        ctx.getExternalFilesDir("scripts") ?: File(ctx.filesDir, "scripts")
    fun logs(ctx: Context): File =
        ctx.getExternalFilesDir("logs") ?: File(ctx.filesDir, "logs")
}

/**
 * 引擎日志落盘：Lua print / 常驻脚本错误 → logs/engine.log。
 * 供 app 内「文件浏览-日志」查看（对齐 iOS logdir）。
 * 超过 MAX 字节从头重写（简单截断，防无限增长）。
 */
object EngineLog {
    @Volatile var logFile: File? = null
    private const val MAX = 256 * 1024

    @Synchronized
    fun append(s: String) {
        val f = logFile ?: return
        try {
            f.parentFile?.mkdirs()
            if (f.length() > MAX) f.writeText(s) else f.appendText(s)
        } catch (_: Exception) {}
    }
}
