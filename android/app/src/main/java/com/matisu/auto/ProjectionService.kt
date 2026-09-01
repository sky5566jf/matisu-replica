package com.matisu.auto

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log

/**
 * MediaProjection 常驻抓帧服务（Android 设备端图色的帧源）。
 * 一次授权后常驻：VirtualDisplay -> ImageReader，线程安全取最新帧 Bitmap。
 */
class ProjectionService : Service() {

    companion object {
        var instance: ProjectionService? = null
        var resultCode: Int = 0
        var resultData: Intent? = null

        /** 最新帧（调用方不得 recycle 原图；用 copy 或立即读像素） */
        @Volatile private var frame: Bitmap? = null
        @Volatile var frameW = 0
        @Volatile var frameH = 0

        fun latestFrame(): Bitmap? = frame
    }

    private var projection: MediaProjection? = null
    private var reader: ImageReader? = null
    private var vdisplay: VirtualDisplay? = null
    private var polling = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        instance = this
        // 前台服务（API 29+ mediaProjection 类型必须）
        val nm = getSystemService(NotificationManager::class.java)
        val chId = "matisu_projection"
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel(chId, "MatisuAuto 投屏", NotificationManager.IMPORTANCE_LOW))
        }
        val notif: Notification = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, chId).setContentTitle("MatisuAuto 图色服务运行中").setSmallIcon(android.R.drawable.ic_menu_camera).build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setContentTitle("MatisuAuto 图色服务运行中").setSmallIcon(android.R.drawable.ic_menu_camera).build()
        }
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(1, notif, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(1, notif)
        }

        if (projection == null && resultData != null) {
            val mpm = getSystemService(MediaProjectionManager::class.java)
            projection = mpm.getMediaProjection(resultCode, resultData!!)
            val dm = resources.displayMetrics
            frameW = dm.widthPixels; frameH = dm.heightPixels
            reader = ImageReader.newInstance(frameW, frameH, PixelFormat.RGBA_8888, 2)
            vdisplay = projection!!.createVirtualDisplay(
                "matisu", frameW, frameH, dm.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, reader!!.surface, null, null)
            startPolling()
            Log.i("MatisuAuto", "ProjectionService started ${frameW}x${frameH}")
        }
        return START_STICKY
    }

    private fun startPolling() {
        if (polling) return
        polling = true
        val handler = Handler(Looper.getMainLooper())
        val task = object : Runnable {
            override fun run() {
                try {
                    val img: Image? = reader?.acquireLatestImage()
                    img?.let {
                        val plane = it.planes[0]
                        val buf = plane.buffer
                        val rowStride = plane.rowStride
                        val pixelStride = plane.pixelStride
                        val w = frameW; val h = frameH
                        val bmp = Bitmap.createBitmap(w + (rowStride - pixelStride * w) / pixelStride, h, Bitmap.Config.ARGB_8888)
                        bmp.copyPixelsFromBuffer(buf)
                        val cropped = Bitmap.createBitmap(bmp, 0, 0, w, h)
                        frame = cropped
                        it.close()
                    }
                } catch (e: Exception) {
                    Log.w("MatisuAuto", "frame poll: ${e.message}")
                }
                handler.postDelayed(this, 120)   // ~8fps 足够图色用
            }
        }
        handler.post(task)
    }

    override fun onDestroy() {
        polling = false
        try { vdisplay?.release() } catch (_: Exception) {}
        try { reader?.close() } catch (_: Exception) {}
        try { projection?.stop() } catch (_: Exception) {}
        instance = null
        super.onDestroy()
    }
}
