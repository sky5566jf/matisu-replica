package com.matisu.auto

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast

class MainActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // TODO(Phase 1+): 接入 luaj，加载 common/lua-api/core.lua，运行用户脚本：
        //   val g = JsePlatform.standardGlobals()
        //   g.load(File("core.lua")).call()
        //   g.load(File("demo.lua")).call()
        // 并把 AutoAccessibilityService 的触控/节点方法桥接为 Lua 的 touch.* / node.*

        if (!isAccessibilityEnabled()) {
            Toast.makeText(this, "请先开启 MatisuAuto 无障碍服务", Toast.LENGTH_LONG).show()
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        } else {
            Toast.makeText(this, "MatisuAuto 已就绪 (Phase 0)", Toast.LENGTH_SHORT).show()
        }
    }

    private fun isAccessibilityEnabled(): Boolean {
        val id = "$packageName/.AutoAccessibilityService"
        val enabled = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        return enabled.contains(id)
    }
}
