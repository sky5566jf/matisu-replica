package com.matisu.auto

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.Socket
import kotlin.concurrent.thread

/**
 * MatisuAuto 主界面（对齐 iOS MainVC）：
 *  1. 设备信息卡：设备名称/系统版本/设备型号/屏幕尺寸/本机IP/存储容量
 *  2. 启动服务/停止服务 + 状态行（:18183 探测）
 *  3. 文件浏览：日志 / 工作目录（FileListActivity）
 *  4. 保留无障碍引导 + 投屏授权自动闭环（图色帧源）
 */
class MainActivity : Activity() {

    companion object {
        private const val REQ_PROJECTION = 1001
        /** 每进程只自动请求一次投屏授权 */
        @Volatile private var projectionAsked = false
    }

    private val handler = Handler(Looper.getMainLooper())
    private lateinit var statusView: TextView
    private lateinit var hintView: TextView
    private lateinit var infoView: TextView

    private val probeTick = object : Runnable {
        override fun run() {
            refreshStatus()
            handler.postDelayed(this, 2000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        buildUi()
        handleScheme(intent)
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        intent?.let { handleScheme(it) }
    }

    override fun onResume() {
        super.onResume()
        refreshDeviceInfo()
        handler.removeCallbacks(probeTick)
        handler.post(probeTick)
        maybeRequestProjection()
    }

    override fun onPause() {
        super.onPause()
        handler.removeCallbacks(probeTick)
    }

    // ---------------- matisuauto://workdir|logdir ----------------
    private fun handleScheme(i: Intent) {
        val uri = i.data ?: return
        if (uri.scheme != "matisuauto") return
        when (uri.host) {
            "workdir" -> FileListActivity.open(this, MatisuDirs.scripts(this), "工作目录")
            "logdir" -> FileListActivity.open(this, MatisuDirs.logs(this), "日志")
        }
    }

    // ---------------- UI ----------------
    private fun dp(v: Int) = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    private fun roundBg(color: Int, radiusDp: Int): GradientDrawable {
        val d = GradientDrawable()
        d.setColor(color)
        d.cornerRadius = dp(radiusDp).toFloat()
        return d
    }

    private fun card(): LinearLayout {
        val l = LinearLayout(this)
        l.orientation = LinearLayout.VERTICAL
        l.setPadding(dp(14), dp(10), dp(14), dp(12))
        val p = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        p.setMargins(0, 0, 0, dp(12))
        l.layoutParams = p
        l.background = roundBg(Color.WHITE, 12)
        return l
    }

    private fun cardTitle(text: String): TextView {
        val t = TextView(this)
        t.text = text
        t.textSize = 15f
        t.setTypeface(null, android.graphics.Typeface.BOLD)
        t.setTextColor(Color.parseColor("#1C1C1E"))
        t.setPadding(0, 0, 0, dp(6))
        return t
    }

    private fun actionBtn(text: String, color: String): Button {
        val b = Button(this)
        b.text = text
        b.textSize = 14f
        b.setTextColor(Color.WHITE)
        b.background = roundBg(Color.parseColor(color), 10)
        val p = LinearLayout.LayoutParams(0, dp(42), 1f)
        p.setMargins(dp(4), dp(2), dp(4), dp(2))
        b.layoutParams = p
        return b
    }

    private fun buildUi() {
        val root = ScrollView(this)
        root.setBackgroundColor(Color.parseColor("#F2F2F6"))
        val col = LinearLayout(this)
        col.orientation = LinearLayout.VERTICAL
        col.setPadding(dp(14), dp(14), dp(14), dp(14))
        root.addView(col)

        val title = TextView(this)
        title.text = "MatisuAuto"
        title.textSize = 20f
        title.setTypeface(null, android.graphics.Typeface.BOLD)
        title.setTextColor(Color.parseColor("#1C1C1E"))
        title.setPadding(dp(2), 0, 0, dp(10))
        col.addView(title)

        // ---- 设备信息卡 ----
        val infoCard = card()
        infoCard.addView(cardTitle("设备信息"))
        infoView = TextView(this)
        infoView.textSize = 13.5f
        infoView.setTextColor(Color.parseColor("#3A3A3C"))
        infoView.setLineSpacing(dp(3).toFloat(), 1.0f)
        infoCard.addView(infoView)
        col.addView(infoCard)

        // ---- 服务控制卡（对齐 iOS：设备信息卡后紧跟启动/停止服务按钮，无独立标题）----
        val svcCard = card()
        val btnRow = LinearLayout(this)
        btnRow.orientation = LinearLayout.HORIZONTAL
        val startBtn = actionBtn("启动服务", "#0A84FF")
        val stopBtn = actionBtn("停止服务", "#FF453A")
        startBtn.setOnClickListener { onStartService() }
        stopBtn.setOnClickListener { onStopService() }
        btnRow.addView(startBtn)
        btnRow.addView(stopBtn)
        svcCard.addView(btnRow)
        statusView = TextView(this)
        statusView.textSize = 13.5f
        statusView.setPadding(dp(2), dp(8), 0, 0)
        svcCard.addView(statusView)
        hintView = TextView(this)
        hintView.textSize = 12.5f
        hintView.setTextColor(Color.parseColor("#FF453A"))
        hintView.setPadding(dp(2), dp(4), 0, 0)
        hintView.visibility = View.GONE
        svcCard.addView(hintView)
        col.addView(svcCard)

        // ---- 文件浏览卡 ----
        val fileCard = card()
        fileCard.addView(cardTitle("文件浏览"))
        val fileRow = LinearLayout(this)
        fileRow.orientation = LinearLayout.HORIZONTAL
        val logBtn = actionBtn("日志", "#5E5CE6")
        val workBtn = actionBtn("工作目录", "#5E5CE6")
        logBtn.setOnClickListener {
            FileListActivity.open(this, MatisuDirs.logs(this), "日志")
        }
        workBtn.setOnClickListener {
            FileListActivity.open(this, MatisuDirs.scripts(this), "工作目录")
        }
        fileRow.addView(logBtn)
        fileRow.addView(workBtn)
        fileCard.addView(fileRow)
        col.addView(fileCard)

        setContentView(root)
    }

    // ---------------- 设备信息 ----------------
    private fun refreshDeviceInfo() {
        val name = try {
            Settings.Global.getString(contentResolver, "device_name")
        } catch (_: Exception) { null } ?: Build.MODEL
        val sys = "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})"
        val dm = android.util.DisplayMetrics()
        @Suppress("DEPRECATION")
        windowManager.defaultDisplay.getRealMetrics(dm)
        val screen = "${dm.widthPixels}x${dm.heightPixels}"
        val ip = localIp() ?: "未连接"
        val st = StatFs(Environment.getDataDirectory().absolutePath)
        val avail = st.availableBytes / 1e9
        val total = st.totalBytes / 1e9
        infoView.text = buildString {
            append("设备名称：").append(name).append('\n')
            append("系统版本：").append(sys).append('\n')
            append("设备型号：").append(Build.MODEL).append('\n')
            append("屏幕尺寸：").append(screen).append('\n')
            append("本机IP：").append(ip).append('\n')
            append("存储容量：").append(String.format("%.1f / %.1f GB", avail, total))
        }
    }

    private fun localIp(): String? {
        try {
            val ifs = NetworkInterface.getNetworkInterfaces() ?: return null
            for (ni in ifs) {
                if (!ni.isUp || ni.isLoopback) continue
                val n = ni.name.lowercase()
                if (!(n.startsWith("wlan") || n.startsWith("eth") ||
                      n.startsWith("rmnet") || n.startsWith("pdp") || n.startsWith("ccmni"))) continue
                val addrs = ni.inetAddresses
                while (addrs.hasMoreElements()) {
                    val a = addrs.nextElement()
                    if (a is Inet4Address && !a.isLoopbackAddress) return a.hostAddress
                }
            }
            // 兜底：任意非回环 IPv4
            val ifs2 = NetworkInterface.getNetworkInterfaces() ?: return null
            for (ni in ifs2) {
                if (!ni.isUp || ni.isLoopback) continue
                val addrs = ni.inetAddresses
                while (addrs.hasMoreElements()) {
                    val a = addrs.nextElement()
                    if (a is Inet4Address && !a.isLoopbackAddress) return a.hostAddress
                }
            }
        } catch (_: Exception) {}
        return null
    }

    // ---------------- 服务状态 ----------------
    private fun isAccessibilityEnabled(): Boolean {
        val short = "$packageName/.AutoAccessibilityService"
        val full = "$packageName/$packageName.AutoAccessibilityService"
        val enabled = Settings.Secure.getString(
            contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        return enabled.contains(short) || enabled.contains(full)
    }

    private fun refreshStatus() {
        thread {
            val accOn = isAccessibilityEnabled()
            val portOk = try {
                Socket("127.0.0.1", 18183).use { true }
            } catch (_: Exception) { false }
            runOnUiThread {
                when {
                    !accOn -> {
                        statusView.text = "服务状态：🔴 无障碍服务未开启"
                        statusView.setTextColor(Color.parseColor("#FF453A"))
                        hintView.text = "点「启动服务」前往系统设置开启 MatisuAuto 无障碍服务"
                        hintView.visibility = View.VISIBLE
                    }
                    portOk -> {
                        statusView.text = "服务状态：🟢 运行中（:18183）"
                        statusView.setTextColor(Color.parseColor("#34C759"))
                        hintView.visibility = View.GONE
                    }
                    else -> {
                        statusView.text = "服务状态：🟡 已停止"
                        statusView.setTextColor(Color.parseColor("#FF9F0A"))
                        hintView.visibility = View.GONE
                    }
                }
            }
        }
    }

    private fun onStartService() {
        if (!isAccessibilityEnabled()) {
            Toast.makeText(this, "请先开启 MatisuAuto 无障碍服务", Toast.LENGTH_LONG).show()
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
            return
        }
        sendBroadcast(Intent(AutoAccessibilityService.ACTION_START_ENGINE).setPackage(packageName))
        Toast.makeText(this, "已请求启动服务", Toast.LENGTH_SHORT).show()
        handler.postDelayed({ refreshStatus() }, 500)
    }

    private fun onStopService() {
        sendBroadcast(Intent(AutoAccessibilityService.ACTION_STOP_ENGINE).setPackage(packageName))
        Toast.makeText(this, "已请求停止服务", Toast.LENGTH_SHORT).show()
        handler.postDelayed({ refreshStatus() }, 500)
    }

    // ---------------- 投屏授权（图色帧源，自动闭环） ----------------
    private fun maybeRequestProjection() {
        if (projectionAsked) return
        if (!isAccessibilityEnabled()) return
        if (ProjectionService.instance != null) return
        projectionAsked = true
        AutoAccessibilityService.pendingAutoAcceptProjection = true
        val mpm = getSystemService(MediaProjectionManager::class.java)
        startActivityForResult(mpm.createScreenCaptureIntent(), REQ_PROJECTION)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_PROJECTION) {
            if (resultCode == RESULT_OK && data != null) {
                ProjectionService.resultCode = resultCode
                ProjectionService.resultData = data
                startForegroundService(Intent(this, ProjectionService::class.java))
                Toast.makeText(this, "图色帧源已启动", Toast.LENGTH_SHORT).show()
            } else {
                Toast.makeText(this, "投屏授权被拒：图色功能不可用（触控/脚本仍可用）", Toast.LENGTH_LONG).show()
            }
        }
    }
}
