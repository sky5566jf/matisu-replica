package com.matisu.auto

import android.app.AlertDialog
import android.content.Context
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * showUI 动态参数界面（WebView 渲染）——语义移植自原版 懒人精灵 showUI.lua（ts 风格）。
 *
 * 用法（Lua）：
 *   local ok, v1, v2, ... = showUI('JSON字符串 或 table')
 * uitable 字段：
 *   title, width, height, timer(秒，到时自动确认), config(持久化名),
 *   cancelname/okname(按钮文字), views = { {type="Edit", caption=, text=默认, prompt=},
 *     {type="EditMulti", rows=, text=, prompt=}, {type="Label", text=, color=, background=, align=},
 *     {type="RadioGroup", list="a,b,c" 或 item={...}, select=默认下标或文本},
 *     {type="ComboBox", list/item, select=}, {type="CheckBoxGroup", list/item, select=下标串"@"},
 *     {type="Image", src=}, {type="Iframe", src=} }
 * 返回：确认 → 1, 值1, 值2...（Edit=文本, ComboBox/RadioGroup=选中下标(0起), CheckBoxGroup=选中下标'@'串）
 *       取消 → 0
 * config：确认时把值以 '###' 拼接存 <externalFiles>/uicfg/<config>.xcfg，下次自动回填。
 */
object ShowUI {
    @Volatile private var resultJson: String? = null
    private var latch: CountDownLatch? = null
    private var dialog: AlertDialog? = null

    class Bridge {
        @JavascriptInterface
        fun post(json: String) {
            resultJson = json
            latch?.countDown()
        }
    }

    /** 阻塞显示 UI，返回 {"Submit":0/1,"Data":[...]} 原始 JSON（超时/异常返回 null） */
    fun showBlocking(ctx: Context, uitable: JSONObject, timeoutSec: Long): String? {
        resultJson = null
        val l = CountDownLatch(1)
        latch = l
        val html = buildHtml(uitable)
        val timerSec = uitable.optInt("timer", 0)
        val ready = CountDownLatch(1)
        var web: WebView? = null
        var dlg: AlertDialog? = null
        val main = android.os.Handler(android.os.Looper.getMainLooper())
        main.post {
            val w = WebView(ctx)
            w.settings.javaScriptEnabled = true
            w.settings.domStorageEnabled = true
            w.addJavascriptInterface(Bridge(), "MatisuBridge")
            w.webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView?, url: String?) { ready.countDown() }
            }
            w.loadDataWithBaseURL(null, html, "text/html", "utf-8", null)
            val builder = AlertDialog.Builder(ctx, android.R.style.Theme_DeviceDefault_Light_NoActionBar_Fullscreen)
                .setView(w)
                .setCancelable(false)
            dlg = builder.create()
            dlg?.show()
            dlg?.window?.setLayout(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                android.view.ViewGroup.LayoutParams.MATCH_PARENT)
            web = w
        }
        try {
            // JS 里的 timer 到时也会自动提交；这里只兜底总超时
            val total = (if (timerSec > 0) timerSec + 30 else 3600).coerceAtMost(7200)
            if (!l.await(total, TimeUnit.SECONDS)) {
                EngineLog.append("[WARN] showUI 等待超时\n")
            }
        } catch (_: InterruptedException) {
        }
        main.post {
            try { dlg?.dismiss() } catch (_: Throwable) {}
            try { web?.destroy() } catch (_: Throwable) {}
        }
        dialog = dlg
        return resultJson
    }

    // ---------------- HTML 生成（自包含，不依赖 mui） ----------------
    private fun esc(s: String?): String =
        (s ?: "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")

    /** 颜色：数字直接用；'r,g,b' 字符串转 0xRRGGBB（对齐原版 tscolor，注意原版拼法 = R*65536+G*256+B） */
    private fun colorCss(v: Any?): String {
        return when (v) {
            is Number -> String.format("#%06X", v.toInt() and 0xFFFFFF)
            is String -> {
                val m = Regex("\\s*(\\d+)\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)\\s*").find(v)
                if (m != null) {
                    val r = m.groupValues[1].toInt() and 0xFF
                    val g = m.groupValues[2].toInt() and 0xFF
                    val b = m.groupValues[3].toInt() and 0xFF
                    String.format("#%02X%02X%02X", r, g, b)
                } else ""
            }
            else -> ""
        }
    }

    private fun itemsOf(ut: JSONObject): List<String> {
        val arr = ut.optJSONArray("item")
        if (arr != null) return (0 until arr.length()).map { arr.optString(it) }
        val list = ut.optString("list", "")
        if (list.isNotEmpty()) return list.split(",").map { it.trim() }
        return emptyList()
    }

    /** select 字段：默认下标（0 起）或默认文本 → 返回 0 起下标或 -1 */
    private fun selectIdx(ut: JSONObject, items: List<String>): Int {
        val v = ut.opt("select") ?: return -1
        if (v is Number) return v.toInt()
        val s = v.toString()
        s.toIntOrNull()?.let { return it }
        return items.indexOf(s)
    }

    private fun styleOf(ut: JSONObject): String {
        val sb = StringBuilder()
        colorCss(ut.opt("background")).takeIf { it.isNotEmpty() }?.let { sb.append("background-color:$it;") }
        colorCss(ut.opt("color")).takeIf { it.isNotEmpty() }?.let { sb.append("color:$it;") }
        return sb.toString()
    }

    private fun elementHtml(ut: JSONObject, cfgv: String?): String {
        val type = ut.optString("type", "Label")
        val st = styleOf(ut)
        return when (type) {
            "Label" -> {
                val text = (ut.optString("text", "")).replace("\n", "<br>")
                "<div class=\"card\" style=\"$st\"><h4 align=\"${ut.optString("align", "center")}\">$text</h4></div>"
            }
            "Edit" -> {
                val def = cfgv ?: ut.optString("text", "")
                "<form class=\"card\" name=\"input\"><div class=\"row\" style=\"$st\">" +
                    "<label>${esc(ut.optString("caption", ""))}</label>" +
                    "<input type=\"text\" value=\"${esc(def)}\" placeholder=\"${esc(ut.optString("prompt", ""))}\">" +
                    "</div></form>"
            }
            "EditMulti" -> {
                val def = cfgv ?: ut.optString("text", "")
                "<form class=\"card\" name=\"input\" style=\"$st\">" +
                    "<textarea rows=\"${ut.optInt("rows", 2)}\" placeholder=\"${esc(ut.optString("prompt", ""))}\">${esc(def)}</textarea>" +
                    "</form>"
            }
            "RadioGroup" -> {
                val items = itemsOf(ut)
                val def = cfgv?.toIntOrNull() ?: selectIdx(ut, items)
                val sb = StringBuilder()
                items.forEachIndexed { i, itv ->
                    val chk = if (i == def) " checked" else ""
                    sb.append("<div class=\"row radio\" style=\"$st\"><label>${esc(itv)}</label>" +
                        "<input type=\"radio\" name=\"vradio\"$chk></div>")
                }
                "<form class=\"card\" name=\"radio\">$sb</form>"
            }
            "ComboBox" -> {
                val items = itemsOf(ut)
                val def = cfgv?.toIntOrNull() ?: selectIdx(ut, items)
                val sb = StringBuilder()
                items.forEachIndexed { i, itv ->
                    val sel = if (i == def) " selected" else ""
                    sb.append("<option value=\"$i\"$sel>${esc(itv)}</option>")
                }
                "<form class=\"card\" name=\"select\"><select class=\"sel\" style=\"$st\">$sb</select></form>"
            }
            "CheckBoxGroup" -> {
                val items = itemsOf(ut)
                // select: 下标串"0@2" / 数组 / '1','0'位串；cfgv 同款
                val checked = HashSet<Int>()
                val raw = cfgv ?: when (val sv = ut.opt("select")) {
                    is String -> sv
                    is org.json.JSONArray -> (0 until sv.length()).joinToString("@") { sv.opt(it).toString() }
                    else -> ""
                }
                if (raw.isNotEmpty() && raw.contains("@")) {
                    raw.split("@").forEach { it.trim().toIntOrNull()?.let { ix -> checked.add(ix) } }
                } else if (raw.length == items.size && raw.all { it == '0' || it == '1' }) {
                    raw.forEachIndexed { i, c -> if (c == '1') checked.add(i) }
                } else raw.toIntOrNull()?.let { checked.add(it) }
                val sb = StringBuilder()
                items.forEachIndexed { i, itv ->
                    val chk = if (checked.contains(i)) " checked" else ""
                    sb.append("<div class=\"row radio\" style=\"$st\"><label>${esc(itv)}</label>" +
                        "<input type=\"checkbox\" name=\"vcheckbox\"$chk></div>")
                }
                "<form class=\"card\" name=\"checkbox\">$sb</form>"
            }
            "Image" -> "<div class=\"card\" style=\"$st\"><img src=\"${esc(ut.optString("src", ""))}\" style=\"width:100%\"></div>"
            "Iframe" -> "<div class=\"card\"><iframe height=\"100%\" width=\"100%\" src=\"${esc(ut.optString("src", ""))}\" frameborder=\"0\"></iframe></div>"
            else -> ""
        }
    }

    internal fun buildHtml(ut: JSONObject): String {
        val views = ut.optJSONArray("views") ?: JSONArray()
        // config 回填：读持久化值按 views 顺序（跳过 Label/Image/Iframe）
        val cfgName = ut.optString("config", "")
        val cfgList = mutableListOf<String?>()
        if (cfgName.isNotEmpty()) {
            val f = uicfgFile(ut, cfgName)
            if (f != null && f.isFile) {
                val raw = f.readText(Charsets.UTF_8).removePrefix("ui_input::::")
                cfgList.addAll(raw.split("###").map { if (it.isEmpty()) null else it })
            }
        }
        val sb = StringBuilder()
        var ci = 0
        for (i in 0 until views.length()) {
            val v = views.optJSONObject(i) ?: continue
            val t = v.optString("type", "Label")
            if (t == "Label" || t == "Image" || t == "Iframe") {
                sb.append(elementHtml(v, null))
            } else {
                sb.append(elementHtml(v, cfgList.getOrNull(ci)))
                ci++
            }
        }
        val timer = ut.optInt("timer", 0)
        val title = esc(ut.optString("title", ""))
        val cancelName = esc(ut.optString("cancelname", ut.optJSONArray("button")?.optString(0) ?: "取消"))
        val okName = esc(ut.optString("okname", ut.optJSONArray("button")?.optString(1) ?: "确认"))
        val timerJs = if (timer > 0) "var left=$timer;setInterval(function(){var e=document.getElementById('timex');e.innerText=left;left--;if(left<0){doSubmit(1);}},1000);" else ""
        return """<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<title>$title</title>
<style>
body{margin:0;font-family:sans-serif;background:#f2f2f7;}
#bar{position:fixed;top:0;left:0;right:0;height:48px;background:#fff;border-bottom:1px solid #ddd;display:flex;align-items:center;justify-content:center;}
#bar h1{font-size:18px;margin:0;}
#timex{position:absolute;right:14px;color:#e64340;font-size:14px;}
#foot{position:fixed;bottom:0;left:0;right:0;height:56px;background:#fff;border-top:1px solid #ddd;display:flex;align-items:center;justify-content:center;gap:12px;}
#foot button{width:40%;height:38px;font-size:16px;border:none;border-radius:6px;color:#fff;}
#btnCancel{background:#e64340;} #btnOk{background:#1aad19;}
#content{position:fixed;top:48px;bottom:56px;left:0;right:0;overflow-y:auto;padding:10px;}
.card{background:#fff;border-radius:8px;margin:8px 0;padding:10px 12px;box-shadow:0 1px 2px rgba(0,0,0,.06);}
.row{display:flex;align-items:center;padding:8px 0;border-bottom:1px solid #f0f0f0;}
.row label{flex:1;font-size:15px;}
.row input[type=text],textarea{flex:1;font-size:15px;border:none;outline:none;background:transparent;}
textarea{width:97%;resize:vertical;}
.radio{justify-content:space-between;}
.radio input{width:20px;height:20px;}
.sel{width:100%;font-size:15px;padding:6px;border:1px solid #ddd;border-radius:4px;background:#fff;}
</style></head><body>
<div id="bar"><h1>$title</h1><span id="timex"></span></div>
<div id="content">$sb</div>
<div id="foot"><button id="btnCancel" onclick="doSubmit(0)">$cancelName</button>
<button id="btnOk" onclick="doSubmit(1)">$okName</button></div>
<script>
function collect(){
  var out=[];
  var forms=document.querySelectorAll('form');
  for(var i=0;i<forms.length;i++){
    var f=forms[i],n=f.name;
    if(n==='input'){var inp=f.querySelector('input[type=text],textarea');out.push(inp?inp.value:'');}
    else if(n==='select'){var s=f.querySelector('select');out.push(s?s.value:'0');}
    else if(n==='radio'){var rs=f.querySelectorAll('input[type=radio]');var r='0';for(var j=0;j<rs.length;j++){if(rs[j].checked)r=String(j);}out.push(r);}
    else if(n==='checkbox'){var cs=f.querySelectorAll('input[type=checkbox]');var a=[];for(var j=0;j<cs.length;j++){if(cs[j].checked)a.push(j);}out.push(a.join('@'));}
  }
  return out;
}
function doSubmit(v){
  MatisuBridge.post(JSON.stringify({Submit:v,Data:collect()}));
}
$timerJs
</script></body></html>"""
    }

    private fun uicfgFile(ut: JSONObject, name: String): File? {
        val ctx = AutoAccessibilityService.instance ?: return null
        val dir = ctx.getExternalFilesDir("uicfg") ?: return null
        val safe = name.replace(Regex("[^A-Za-z0-9_\\-\\u4e00-\\u9fa5]"), "_")
        return File(dir, "$safe.xcfg")
    }

    /**
     * 供 LuaEngine 调用：阻塞展示并返回 Lua 多值语义。
     * 返回数组：[0]=submit(0/1)，[1..]=各控件值（仅确认时）。
     */
    fun runForLua(ctx: Context, uitable: JSONObject): List<String> {
        val timerSec = uitable.optInt("timer", 0).toLong()
        val raw = showBlocking(ctx, uitable, timerSec + 60)
        val cfgName = uitable.optString("config", "")
        if (raw == null) return listOf("0")
        val j = JSONObject(raw)
        val submit = j.optInt("Submit", 0)
        val data = j.optJSONArray("Data") ?: JSONArray()
        val vals = (0 until data.length()).map { data.optString(it) }
        if (submit == 1 && cfgName.isNotEmpty()) {
            val f = uicfgFile(uitable, cfgName)
            if (f != null) {
                try { f.parentFile?.mkdirs(); f.writeText("ui_input::::" + vals.joinToString("###"), Charsets.UTF_8) } catch (_: Throwable) {}
            }
        }
        if (submit == 1) return listOf("1") + vals
        return listOf("0")
    }
}
