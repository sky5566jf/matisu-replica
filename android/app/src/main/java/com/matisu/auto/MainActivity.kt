package com.matisu.auto

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast

class MainActivity : Activity() {

    companion object { private const val REQ_PROJECTION = 1001 }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (!isAccessibilityEnabled()) {
            Toast.makeText(this, "请先开启 MatisuAuto 无障碍服务", Toast.LENGTH_LONG).show()
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
            return
        }
        // 无障碍就绪 → 请求投屏授权（图色帧源；授权弹窗由无障碍服务自动点「立即开始」）
        requestProjection()
    }

    private fun requestProjection() {
        val mpm = getSystemService(MediaProjectionManager::class.java)
        // 异步等无障碍服务起来后自动点授权按钮
        AutoAccessibilityService.pendingAutoAcceptProjection = true
        startActivityForResult(mpm.createScreenCaptureIntent(), REQ_PROJECTION)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_PROJECTION) {
            if (resultCode == RESULT_OK && data != null) {
                ProjectionService.resultCode = resultCode
                ProjectionService.resultData = data
                startForegroundService(Intent(this, ProjectionService::class.java))
                Toast.makeText(this, "MatisuAuto 已就绪（图色帧源已启动）", Toast.LENGTH_SHORT).show()
            } else {
                Toast.makeText(this, "投屏授权被拒：图色功能不可用（触控/脚本仍可用）", Toast.LENGTH_LONG).show()
            }
            finish()
        }
    }

    private fun isAccessibilityEnabled(): Boolean {
        // settings 里可能是缩写（pkg/.Service）或展开（pkg/pkg.Service）形式，两种都认
        val short = "$packageName/.AutoAccessibilityService"
        val full = "$packageName/$packageName.AutoAccessibilityService"
        val enabled = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        return enabled.contains(short) || enabled.contains(full)
    }
}
