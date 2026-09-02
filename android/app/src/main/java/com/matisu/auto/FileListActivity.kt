package com.matisu.auto

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.TypedValue
import android.view.View
import android.view.ViewGroup
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.TextView
import android.widget.Toast
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 文件浏览（对齐 iOS FileListVC）：
 *  顶部：‹返回 | 标题 | 刷新 | 批量/完成
 *  列表：目录优先按名排序；条目 = 名称 + 大小·修改时间；点目录递归进入；点文件预览
 *  批量模式：行首勾选 + 底部工具条【删除(N)】【全选】，二次确认后删除
 *  长按：单文件删除（二次确认）
 */
class FileListActivity : Activity() {

    companion object {
        fun open(ctx: Context, dir: File, title: String) {
            ctx.startActivity(Intent(ctx, FileListActivity::class.java).apply {
                putExtra("dir", dir.absolutePath)
                putExtra("name", title)
            })
        }
    }

    private lateinit var dir: File
    private lateinit var listView: ListView
    private lateinit var emptyView: TextView
    private lateinit var bottomBar: LinearLayout
    private lateinit var batchBtn: Button
    private lateinit var deleteBtn: Button
    private lateinit var selAllBtn: Button
    private var batch = false
    private val selected = mutableSetOf<String>()
    private var entries = listOf<File>()

    private fun dp(v: Int) = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    private fun roundBg(color: Int, radiusDp: Int): GradientDrawable {
        val d = GradientDrawable()
        d.setColor(color)
        d.cornerRadius = dp(radiusDp).toFloat()
        return d
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        dir = File(intent.getStringExtra("dir") ?: return finish())
        val name = intent.getStringExtra("name") ?: dir.name

        val root = LinearLayout(this)
        root.orientation = LinearLayout.VERTICAL
        root.setBackgroundColor(Color.parseColor("#F2F2F6"))

        // ---- 顶部栏 ----
        val top = LinearLayout(this)
        top.orientation = LinearLayout.HORIZONTAL
        top.gravity = android.view.Gravity.CENTER_VERTICAL
        top.setPadding(dp(8), dp(8), dp(8), dp(8))
        top.setBackgroundColor(Color.WHITE)

        val back = TextView(this)
        back.text = "‹ 返回"
        back.textSize = 15f
        back.setTextColor(Color.parseColor("#0A84FF"))
        back.setPadding(dp(6), dp(4), dp(6), dp(4))
        back.setOnClickListener { finish() }
        top.addView(back)

        val titleTv = TextView(this)
        titleTv.text = name
        titleTv.textSize = 16f
        titleTv.setTypeface(null, Typeface.BOLD)
        titleTv.setTextColor(Color.parseColor("#1C1C1E"))
        titleTv.gravity = android.view.Gravity.CENTER
        titleTv.layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        top.addView(titleTv)

        val refreshBtn = smallBtn("刷新")
        refreshBtn.setOnClickListener { refresh() }
        top.addView(refreshBtn)
        batchBtn = smallBtn("批量")
        batchBtn.setOnClickListener { toggleBatch() }
        top.addView(batchBtn)
        root.addView(top)

        // ---- 列表 ----
        val body = LinearLayout(this)
        body.orientation = LinearLayout.VERTICAL
        body.layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
        listView = ListView(this)
        listView.divider = null
        listView.dividerHeight = 0
        emptyView = TextView(this)
        emptyView.text = "（空）"
        emptyView.gravity = android.view.Gravity.CENTER
        emptyView.setTextColor(Color.parseColor("#8E8E93"))
        emptyView.textSize = 14f
        emptyView.visibility = View.GONE
        body.addView(listView, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.MATCH_PARENT))
        body.addView(emptyView, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.MATCH_PARENT))
        root.addView(body)

        // ---- 批量模式底部工具条 ----
        bottomBar = LinearLayout(this)
        bottomBar.orientation = LinearLayout.HORIZONTAL
        bottomBar.setPadding(dp(8), dp(6), dp(8), dp(6))
        bottomBar.setBackgroundColor(Color.WHITE)
        bottomBar.visibility = View.GONE
        deleteBtn = smallBtn("删除")
        deleteBtn.setOnClickListener { confirmBatchDelete() }
        selAllBtn = smallBtn("全选")
        selAllBtn.setOnClickListener { toggleSelectAll() }
        bottomBar.addView(deleteBtn, LinearLayout.LayoutParams(0, dp(40), 1f))
        bottomBar.addView(selAllBtn, LinearLayout.LayoutParams(0, dp(40), 1f))
        root.addView(bottomBar)

        setContentView(root)

        listView.setOnItemClickListener { _, _, pos, _ -> onItemClick(pos) }
        listView.setOnItemLongClickListener { _, _, pos, _ -> onItemLongPress(pos); true }

        refresh()
    }

    private fun smallBtn(text: String): Button {
        val b = Button(this)
        b.text = text
        b.textSize = 13f
        b.setTextColor(Color.WHITE)
        b.background = roundBg(Color.parseColor("#0A84FF"), 8)
        val p = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(34))
        p.setMargins(dp(4), 0, dp(4), 0)
        b.layoutParams = p
        b.minimumWidth = 0
        b.minWidth = 0
        b.setPadding(dp(10), 0, dp(10), 0)
        return b
    }

    // ---------------- 数据 ----------------
    private fun refresh() {
        val files = dir.listFiles()?.toList() ?: emptyList()
        entries = files.sortedWith(compareBy({ !it.isDirectory }, { it.name.lowercase() }))
        selected.clear()
        listView.adapter = Adapter()
        emptyView.visibility = if (entries.isEmpty()) View.VISIBLE else View.GONE
        listView.visibility = if (entries.isEmpty()) View.GONE else View.VISIBLE
        updateBatchBar()
    }

    private fun fmtSize(n: Long): String = when {
        n >= 1L shl 30 -> String.format("%.1fGB", n / (1L shl 30).toDouble())
        n >= 1L shl 20 -> String.format("%.1fMB", n / (1L shl 20).toDouble())
        n >= 1L shl 10 -> String.format("%.1fKB", n / (1L shl 10).toDouble())
        else -> "${n}B"
    }

    private fun fmtTime(t: Long): String =
        SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault()).format(Date(t))

    private inner class Adapter : ArrayAdapter<File>(this@FileListActivity, 0, entries) {
        override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
            val f = getItem(position)!!
            val row = LinearLayout(context)
            row.orientation = LinearLayout.HORIZONTAL
            row.gravity = android.view.Gravity.CENTER_VERTICAL
            row.setPadding(dp(12), dp(9), dp(12), dp(9))

            val check = TextView(context)
            check.textSize = 16f
            check.setPadding(0, 0, dp(8), 0)
            if (batch) {
                check.text = if (selected.contains(f.absolutePath)) "☑" else "☐"
                check.setTextColor(Color.parseColor("#0A84FF"))
            } else {
                check.text = if (f.isDirectory) "📁" else "📄"
            }
            row.addView(check)

            val col = LinearLayout(context)
            col.orientation = LinearLayout.VERTICAL
            val nameTv = TextView(context)
            nameTv.text = f.name
            nameTv.textSize = 14.5f
            nameTv.setTextColor(Color.parseColor("#1C1C1E"))
            val metaTv = TextView(context)
            metaTv.textSize = 11.5f
            metaTv.setTextColor(Color.parseColor("#8E8E93"))
            metaTv.text = if (f.isDirectory) "文件夹 · ${fmtTime(f.lastModified())}"
                          else "${fmtSize(f.length())} · ${fmtTime(f.lastModified())}"
            col.addView(nameTv)
            col.addView(metaTv)
            row.addView(col, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))

            if (batch && selected.contains(f.absolutePath)) {
                row.setBackgroundColor(Color.parseColor("#E3EFFF"))
            } else {
                row.setBackgroundColor(Color.WHITE)
            }
            return row
        }
    }

    // ---------------- 交互 ----------------
    private fun onItemClick(pos: Int) {
        val f = entries[pos]
        if (batch) {
            if (!selected.add(f.absolutePath)) selected.remove(f.absolutePath)
            (listView.adapter as Adapter).notifyDataSetChanged()
            updateBatchBar()
            return
        }
        if (f.isDirectory) {
            open(this, f, f.name)
        } else {
            preview(f)
        }
    }

    private fun onItemLongPress(pos: Int) {
        if (batch) return
        val f = entries[pos]
        AlertDialog.Builder(this)
            .setTitle("删除文件")
            .setMessage("确定删除「${f.name}」？此操作不可恢复。")
            .setNegativeButton("取消", null)
            .setPositiveButton("删除") { _, _ ->
                val ok = f.deleteRecursively()
                Toast.makeText(this, if (ok) "已删除1个文件" else "删除失败", Toast.LENGTH_SHORT).show()
                refresh()
            }
            .show()
    }

    private fun toggleBatch() {
        batch = !batch
        selected.clear()
        batchBtn.text = if (batch) "完成" else "批量"
        bottomBar.visibility = if (batch) View.VISIBLE else View.GONE
        (listView.adapter as? Adapter)?.notifyDataSetChanged()
        updateBatchBar()
    }

    private fun toggleSelectAll() {
        if (selected.size == entries.size) selected.clear()
        else entries.forEach { selected.add(it.absolutePath) }
        (listView.adapter as? Adapter)?.notifyDataSetChanged()
        updateBatchBar()
    }

    private fun updateBatchBar() {
        deleteBtn.text = "删除 (${selected.size})"
        selAllBtn.text = if (selected.size == entries.size && entries.isNotEmpty()) "取消全选" else "全选"
    }

    private fun confirmBatchDelete() {
        if (selected.isEmpty()) {
            Toast.makeText(this, "请先勾选文件", Toast.LENGTH_SHORT).show()
            return
        }
        AlertDialog.Builder(this)
            .setTitle("删除文件")
            .setMessage("确定删除选中的 ${selected.size} 个文件？此操作不可恢复。")
            .setNegativeButton("取消", null)
            .setPositiveButton("删除") { _, _ ->
                var ok = 0
                var fail = 0
                val targets = entries.filter { selected.contains(it.absolutePath) }
                for (f in targets) {
                    if (f.deleteRecursively()) ok++ else fail++
                }
                Toast.makeText(this,
                    if (fail == 0) "已删除${ok}个文件" else "已删除${ok}个，失败${fail}个",
                    Toast.LENGTH_SHORT).show()
                toggleBatch()   // 退出批量模式
                refresh()
            }
            .show()
    }

    private fun preview(f: File) {
        val txt = try {
            val bytes = f.readBytes()
            val head = bytes.take(400).toByteArray()
            val s = String(head, Charsets.UTF_8)
            if (s.any { it == '�' }) null else s
        } catch (_: Exception) { null }
        AlertDialog.Builder(this)
            .setTitle(f.name)
            .setMessage(txt ?: "（二进制或无法预览的文件）")
            .setPositiveButton("关闭", null)
            .show()
    }
}
