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
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
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
