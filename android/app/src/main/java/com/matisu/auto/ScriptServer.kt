package com.matisu.auto

import android.util.Log
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.ServerSocket
import java.net.Socket
import java.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * MatisuAuto Android 脚本控制服务（:18183，与 iOS daemon :18182 同构指令面）
 * 协议：文本一行一指令，响应 [4 字节大端长度][payload]。
 *
 * 指令：run <b64> / runfile <名> / upload <b64名> <b64内容> / list / delete <名> /
 *       start <b64> / stop / state / ping
 */
class ScriptServer(private val port: Int = 18183) {

    private var serverThread: Thread? = null
    @Volatile private var running = false
    @Volatile private var serverSocket: ServerSocket? = null

    fun start() {
        if (running) return
        running = true
        serverThread = Thread {
            try {
                val ss = ServerSocket(port)
                serverSocket = ss
                Log.i("MatisuAuto", "ScriptServer listening :$port")
                while (running) {
                    try {
                        val cli = ss.accept()
                        Thread { handle(cli) }.start()
                    } catch (_: Exception) {}
                }
            } catch (e: Exception) {
                if (running) Log.e("MatisuAuto", "ScriptServer died: ${e.message}")
            } finally {
                serverSocket = null
                running = false
            }
        }.also { it.isDaemon = true; it.start() }
    }

    /** 停止监听（「停止服务」用）；accept 因 close 抛异常退出循环。 */
    fun stop() {
        running = false
        try { serverSocket?.close() } catch (_: Exception) {}
    }

    private fun respond(cli: Socket, payload: ByteArray) {
        val out = cli.getOutputStream()
        val n = payload.size
        out.write(byteArrayOf((n shr 24).toByte(), (n shr 16).toByte(), (n shr 8).toByte(), n.toByte()))
        out.write(payload)
        out.flush()
    }

    private fun handle(cli: Socket) {
        try {
            val line = BufferedReader(InputStreamReader(cli.getInputStream())).readLine() ?: return
            val parts = line.split(' ', limit = 2)
            val cmd = parts[0]
            val arg = if (parts.size > 1) parts[1] else ""
            val dir = LuaEngine.scriptDir

            when (cmd) {
                "ping" -> respond(cli, "OK\n".toByteArray())

                "run" -> {
                    val src = String(Base64.getDecoder().decode(arg), Charsets.UTF_8)
                    val r = LuaEngine.run(src)
                    val j = JSONObject().put("ok", r.ok).put("output", r.output)
                    if (r.error != null) j.put("error", r.error)
                    respond(cli, j.toString().toByteArray())
                }

                "runfile" -> {
                    val f = dir?.let { File(it, arg) }
                    val j = if (f != null && f.isFile) {
                        val r = LuaEngine.run(f.readText())
                        JSONObject().put("ok", r.ok).put("output", r.output).apply {
                            if (r.error != null) put("error", r.error)
                        }
                    } else JSONObject().put("ok", false).put("output", "").put("error", "script not found: $arg")
                    respond(cli, j.toString().toByteArray())
                }

                "upload" -> {
                    val sp = arg.indexOf(' ')
                    var okw = false
                    if (sp > 0 && dir != null) {
                        val name = String(Base64.getDecoder().decode(arg.substring(0, sp)), Charsets.UTF_8)
                        val content = Base64.getDecoder().decode(arg.substring(sp + 1))
                        if (!name.contains("..")) {
                            dir.mkdirs()
                            File(dir, name).writeBytes(content)
                            okw = true
                        }
                    }
                    respond(cli, (if (okw) "OK\n" else "FAIL\n").toByteArray())
                }

                "readfile" -> {
                    val f = dir?.let { File(it, arg) }
                    if (!arg.contains("..") && f != null && f.isFile) respond(cli, f.readBytes())
                    else respond(cli, ByteArray(0))
                }

                "list" -> {
                    val arr = JSONArray()
                    dir?.listFiles()?.filter { it.isFile }?.forEach { arr.put(it.name) }
                    respond(cli, arr.toString().toByteArray())
                }

                "delete" -> {
                    val okd = !arg.contains("..") && (dir?.let { File(it, arg).delete() } == true)
                    respond(cli, (if (okd) "OK\n" else "FAIL\n").toByteArray())
                }

                "start" -> {
                    val src = String(Base64.getDecoder().decode(arg), Charsets.UTF_8)
                    respond(cli, (if (LuaEngine.start(src)) "OK\n" else "FAIL\n").toByteArray())
                }

                "stop" -> {
                    LuaEngine.stop()
                    respond(cli, "OK\n".toByteArray())
                }

                "state" -> {
                    val j = JSONObject().put("running", LuaEngine.svcRunning)
                        .put("output", LuaEngine.drainOutput())
                    respond(cli, j.toString().toByteArray())
                }

                else -> respond(cli, "unknown command\n".toByteArray())
            }
        } catch (e: Exception) {
            try { respond(cli, ("error: ${e.message}\n").toByteArray()) } catch (_: Exception) {}
        } finally {
            try { cli.close() } catch (_: Exception) {}
        }
    }
}
