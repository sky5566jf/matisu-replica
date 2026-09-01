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

        /** 屏幕逻辑尺寸（脚本坐标系） */
        fun displaySize(): Pair<Int, Int> {
            val ctx = instance ?: return Pair(720, 1280)
            val dm = ctx.resources.displayMetrics
            // 引擎报告横屏 1280x720 设备按开发坐标（宽>高 时与 PC 桥一致）
            return Pair(dm.widthPixels, dm.heightPixels)
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        // 设备端 Lua 引擎：脚本目录 + 指令服务
        LuaEngine.scriptDir = getExternalFilesDir("scripts")
        ScriptServer(18183).start()
        LuaEngine.autoRun()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

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

    private fun dumpNode(node: AccessibilityNodeInfo?, depth: Int, sb: StringBuilder) {
        if (node == null) return
        sb.append("  ".repeat(depth))
        sb.append("${node.className} text=${node.text} desc=${node.contentDescription}\n")
        for (i in 0 until node.childCount) dumpNode(node.getChild(i), depth + 1, sb)
    }

    // ---------------- 截图：需 MediaProjection，Phase 0 留桩 ----------------
    fun screenshot(path: String): String? = null
}
