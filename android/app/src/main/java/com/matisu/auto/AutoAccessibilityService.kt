package com.matisu.auto

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.accessibilityservice.GestureDescription.StrokeDescription
import android.graphics.Path
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * MatisuAuto 无障碍服务：执行 Lua 脚本的触控与界面操作。
 * 宿主（luaj）把 Lua 的 touch.* / node.* 桥接到本类的对应方法。
 */
class AutoAccessibilityService : AccessibilityService() {

    companion object {
        /** 供宿主静态获取实例，用于从 Lua 引擎调用。 */
        var instance: AutoAccessibilityService? = null

        /** MainActivity 置位：有投屏授权弹窗待自动接受 */
        @Volatile var pendingAutoAcceptProjection = false

        /** 引擎启停控制广播（app 主界面「启动服务/停止服务」） */
        const val ACTION_START_ENGINE = "com.matisu.auto.action.START_ENGINE"
        const val ACTION_STOP_ENGINE = "com.matisu.auto.action.STOP_ENGINE"

        private var server: ScriptServer? = null

        @Synchronized fun startEngine() {
            if (server == null) server = ScriptServer(18183)
            server?.start()
        }

        @Synchronized fun stopEngine() {
            LuaEngine.stop()
            server?.stop()
        }

        /** 屏幕逻辑尺寸（脚本坐标系） */
        fun displaySize(): Pair<Int, Int> {
            val ctx = instance ?: return Pair(720, 1280)
            val dm = ctx.resources.displayMetrics
            // 引擎报告横屏 1280x720 设备按开发坐标（宽>高 时与 PC 桥一致）
            return Pair(dm.widthPixels, dm.heightPixels)
        }
    }

    private var controlReceiver: android.content.BroadcastReceiver? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        // 设备端 Lua 引擎：脚本目录 + 日志落盘 + 指令服务
        LuaEngine.scriptDir = MatisuDirs.scripts(this)
        EngineLog.logFile = java.io.File(MatisuDirs.logs(this), "engine.log")
        registerControl()
        startEngine()
        LuaEngine.autoRun()
        // 投屏授权弹窗可能早于服务连接出现（事件不重放）——连接后补点几次
        if (pendingAutoAcceptProjection) retryAutoAccept(0)
    }

    /** 服务刚连上时补点投屏授权「立即开始」（窗口事件在服务连接前发出就不会重放） */
    private fun retryAutoAccept(attempt: Int) {
        if (!pendingAutoAcceptProjection || attempt >= 10) return
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            val root = rootInActiveWindow
            val btn = findButtonText(root, listOf("立即开始", "Start now", "开始", "START NOW"))
            if (btn != null) {
                btn.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                pendingAutoAcceptProjection = false
            } else {
                retryAutoAccept(attempt + 1)
            }
        }, 500)
    }

    override fun onDestroy() {
        super.onDestroy()
        instance = null
        controlReceiver?.let { try { unregisterReceiver(it) } catch (_: Exception) {} }
        controlReceiver = null
    }

    /** 注册引擎启停控制广播（仅本 app，不导出） */
    private fun registerControl() {
        if (controlReceiver != null) return
        val r = object : android.content.BroadcastReceiver() {
            override fun onReceive(context: android.content.Context?, intent: android.content.Intent?) {
                when (intent?.action) {
                    ACTION_START_ENGINE -> startEngine()
                    ACTION_STOP_ENGINE -> stopEngine()
                }
            }
        }
        val filter = android.content.IntentFilter().apply {
            addAction(ACTION_START_ENGINE)
            addAction(ACTION_STOP_ENGINE)
        }
        androidx.core.content.ContextCompat.registerReceiver(
            this, r, filter, androidx.core.content.ContextCompat.RECEIVER_NOT_EXPORTED)
        controlReceiver = r
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // 投屏授权弹窗自动点「立即开始」（自服务闭环，无需人工）
        if (!pendingAutoAcceptProjection) return
        val root = rootInActiveWindow ?: return
        val btn = findButtonText(root, listOf("立即开始", "Start now", "开始", "START NOW"))
        if (btn != null) {
            btn.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            pendingAutoAcceptProjection = false
        }
    }
    override fun onInterrupt() {}

    private fun findButtonText(node: AccessibilityNodeInfo?, texts: List<String>): AccessibilityNodeInfo? {
        if (node == null) return null
        val t = node.text?.toString()
        if (t != null && texts.any { t.contains(it, ignoreCase = true) } && node.isClickable) return node
        for (i in 0 until node.childCount) {
            val r = findButtonText(node.getChild(i), texts)
            if (r != null) return r
        }
        return null
    }

    // ---------------- 触控：基于 dispatchGesture（API 24+） ----------------
    // 注：dispatchGesture 需在主线程调用。
    fun tap(x: Int, y: Int, delayMs: Long = 1) {
        val path = Path().apply { moveTo(x.toFloat(), y.toFloat()) }
        val stroke = StrokeDescription(path, 0, delayMs.coerceAtLeast(1))
        dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
    }

    fun swipe(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Long) {
        val path = Path().apply {
            moveTo(x1.toFloat(), y1.toFloat())
            lineTo(x2.toFloat(), y2.toFloat())
        }
        val stroke = StrokeDescription(path, 0, durationMs.coerceAtLeast(1))
        dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
    }

    // 多指：Phase 0 先以单指近似实现，后续扩展 pointer 列表
    fun touchDown(finger: Int, x: Int, y: Int) = tap(x, y)
    fun touchMove(finger: Int, x: Int, y: Int) {}
    fun touchUp(finger: Int, x: Int, y: Int) {}

    // ---------------- 键盘 / 输入 ----------------
    fun keyPress(name: String): Boolean {
        val action = when (name.lowercase()) {
            "home" -> GLOBAL_ACTION_HOME
            "back" -> GLOBAL_ACTION_BACK
            "recent", "recents", "app_switch" -> GLOBAL_ACTION_RECENTS
            "notifications" -> GLOBAL_ACTION_NOTIFICATIONS
            "power", "powerdialog" -> GLOBAL_ACTION_POWER_DIALOG
            else -> return false
        }
        return performGlobalAction(action)
    }

    /** 向当前焦点输入框写文本（无障碍 ACTION_SET_TEXT） */
    fun inputText(text: String): Boolean {
        val root = rootInActiveWindow ?: return false
        val target = findFocusedEditable(root) ?: return false
        val args = android.os.Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        }
        return target.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    private fun findFocusedEditable(node: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        if (node == null) return null
        if (node.isFocused && node.isEditable) return node
        for (i in 0 until node.childCount) {
            val r = findFocusedEditable(node.getChild(i))
            if (r != null) return r
        }
        return null
    }

    // ---------------- UI 节点 ----------------
    fun findNodeByText(text: String): AccessibilityNodeInfo? {
        val root = rootInActiveWindow ?: return null
        return dfs(root, text)
    }

    private fun dfs(node: AccessibilityNodeInfo?, text: String): AccessibilityNodeInfo? {
        if (node == null) return null
        val t = node.text?.toString()
        val d = node.contentDescription?.toString()
        if (t == text || d == text) return node
        for (i in 0 until node.childCount) {
            val r = dfs(node.getChild(i), text)
            if (r != null) return r
        }
        return null
    }

    fun clickNode(text: String): Boolean {
        val n = findNodeByText(text) ?: return false
        return n.performAction(AccessibilityNodeInfo.ACTION_CLICK)
    }

    /** 序列化当前窗口节点树，供 Lua 的 node.dump() 返回。 */
    fun dump(): String {
        val root = rootInActiveWindow ?: return ""
        val sb = StringBuilder()
        dumpNode(root, 0, sb)
        // 注意：rootInActiveWindow 返回的节点使用后应 recycle，Phase 0 简化略。
        return sb.toString()
    }

    /** 节点树 JSON dump（供 IDE 节点查看器）：含 bounds/text/desc/class/id/状态位，深度优先。
     *  节点数超 3000 截断防大包。根包一层 {pkg, count, root}。 */
    fun dumpJson(): String {
        val root = rootInActiveWindow ?: return "{\"count\":0}"
        val counter = intArrayOf(0)
        val rootJ = nodeToJson(root, 0, counter) ?: org.json.JSONObject()
        val top = org.json.JSONObject()
        top.put("pkg", root.packageName?.toString() ?: "")
        top.put("count", counter[0])
        top.put("truncated", counter[0] >= 3000)
        top.put("root", rootJ)
        return top.toString()
    }

    private fun nodeToJson(node: AccessibilityNodeInfo?, depth: Int, counter: IntArray): org.json.JSONObject? {
        if (node == null || counter[0] >= 3000) return null
        counter[0]++
        val j = org.json.JSONObject()
        val r = android.graphics.Rect()
        node.getBoundsInScreen(r)
        j.put("b", intArrayOf(r.left, r.top, r.right, r.bottom).let { org.json.JSONArray(it) })
        node.text?.let { j.put("text", it.toString()) }
        node.contentDescription?.let { j.put("desc", it.toString()) }
        node.viewIdResourceName?.let { j.put("id", it) }
        j.put("cls", (node.className ?: "").toString().substringAfterLast('.'))
        if (node.isClickable) j.put("click", true)
        if (node.isCheckable) j.put("checkable", true)
        if (node.isChecked) j.put("checked", true)
        if (node.isEditable) j.put("edit", true)
        if (node.isScrollable) j.put("scroll", true)
        if (!node.isEnabled) j.put("disabled", true)
        val kids = org.json.JSONArray()
        for (i in 0 until node.childCount) {
            val cj = nodeToJson(node.getChild(i), depth + 1, counter) ?: continue
            kids.put(cj)
        }
        if (kids.length() > 0) j.put("kids", kids)
        return j
    }


    private fun dumpNode(node: AccessibilityNodeInfo?, depth: Int, sb: StringBuilder) {
        if (node == null) return
        sb.append("  ".repeat(depth))
        sb.append("${node.className} text=${node.text} desc=${node.contentDescription}\n")
        for (i in 0 until node.childCount) dumpNode(node.getChild(i), depth + 1, sb)
    }

    // ---------------- 截图：需 MediaProjection，Phase 0 留桩 ----------------
    fun screenshot(path: String): String? = null
}
