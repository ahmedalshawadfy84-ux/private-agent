package com.orailnoor.privateagent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Base64
import android.util.DisplayMetrics
import android.util.Log
import android.view.Display
import android.view.WindowManager
import java.io.ByteArrayOutputStream

/**
 * Foreground service that owns the live [MediaProjection] session for
 * PrivateAgent. It captures the screen while a multi-step task is running
 * and keeps the privacy indicator visible while capture is active.
 */
class ScreenCaptureService : Service() {
    companion object {
        private const val TAG = "ScreenCaptureService"
        private const val NOTIFICATION_ID = 4242
        private const val CHANNEL_ID = "screen_capture_channel"
        private const val VIRTUAL_DISPLAY_NAME = "PrivateAgentProjection"
        const val ACTION_START = "com.orailnoor.privateagent.CAPTURE_START"
        const val ACTION_STOP = "com.orailnoor.privateagent.CAPTURE_STOP"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"

        @Volatile
        private var active: ScreenCaptureService? = null

        fun isRunning(): Boolean = active?.projection != null
        fun latestFrame(): String? = active?.latestFrameBase64

        fun stop(context: Context, reason: String) {
            val intent = Intent(context, ScreenCaptureService::class.java).apply {
                action = ACTION_STOP
                putExtra("reason", reason)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Throwable) {
                Log.w(TAG, "Failed to deliver stop intent: ${e.message}")
                active?.stopProjectionFromApp()
                active?.stopForegroundCompat()
                active?.stopSelf()
            }
        }
    }

    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private var density: Int = 0
    private var width: Int = 0
    private var height: Int = 0

    @Volatile
    private var latestFrameBase64: String? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        active = this
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                val reason = intent.getStringExtra("reason") ?: "cancelled"
                Log.d(TAG, "Stop requested: $reason")
                stopProjectionFromApp()
                stopForegroundCompat()
                stopSelf()
                notifyFlutter("stopped", reason)
                return START_NOT_STICKY
            }

            ACTION_START -> {
                val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
                val resultData: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(EXTRA_RESULT_DATA)
                }
                if (resultCode == 0 || resultData == null) {
                    Log.e(TAG, "Missing MediaProjection consent")
                    stopSelf()
                    notifyFlutter("error", "Missing consent payload")
                    return START_NOT_STICKY
                }

                try {
                    startProjection(resultCode, resultData)
                } catch (e: Throwable) {
                    Log.e(TAG, "Failed to start MediaProjection: ${e.message}", e)
                    notifyFlutter("error", e.message ?: "Failed to start MediaProjection")
                    stopProjectionFromApp()
                    stopForegroundCompat()
                    stopSelf()
                    return START_NOT_STICKY
                }
            }

            else -> {
                Log.w(TAG, "Unknown intent action; stopping")
                stopSelf()
                return START_NOT_STICKY
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopProjectionFromApp()
        active = null
        super.onDestroy()
    }

    private fun ensureNotificationChannel() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Screen capture",
                NotificationManager.IMPORTANCE_LOW,
            )
            channel.description = "Keeps screen capture alive while a task is running"
            channel.setShowBadge(false)
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("PrivateAgent")
            .setContentText("Screen sharing is active while the task is running")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }

    private fun startForegroundCompat() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun startProjection(resultCode: Int, data: Intent) {
        if (projection != null) {
            Log.d(TAG, "Projection already active; ignoring duplicate start")
            return
        }

        val metrics = DisplayMetrics()
        val display: Display? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            display
        } else {
            @Suppress("DEPRECATION")
            (getSystemService(Context.WINDOW_SERVICE) as WindowManager).defaultDisplay
        }
        display?.getRealMetrics(metrics)
        width = metrics.widthPixels
        height = metrics.heightPixels
        density = metrics.densityDpi

        val projectionManager =
            getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val mediaProjection = projectionManager.getMediaProjection(resultCode, data)
        if (mediaProjection == null) {
            Log.e(TAG, "MediaProjection was null after consent")
            stopSelf()
            notifyFlutter("error", "MediaProjection unavailable")
            return
        }

        projection = mediaProjection
        mediaProjection.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                Log.d(TAG, "MediaProjection callback onStop fired")
                releaseProjectionResources()
                stopForegroundCompat()
                stopSelf()
                notifyFlutter("stopped", "MediaProjection ended by the system")
            }
        }, mainHandler)

        // Important on Android 14/15: call startForeground only after the
        // MediaProjection consent has been consumed with getMediaProjection().
        startForegroundCompat()

        val reader = ImageReader.newInstance(width, height, 0x1, 2)
        val callback = ImageReader.OnImageAvailableListener { r ->
            var image: android.media.Image? = null
            try {
                image = r.acquireLatestImage()
                if (image == null) return@OnImageAvailableListener
                val planes = image.planes
                val buffer = planes[0].buffer
                val pixelStride = planes[0].pixelStride
                val rowStride = planes[0].rowStride
                val rowPadding = rowStride - pixelStride * width
                val paddedWidth = if (rowPadding > 0) width + rowPadding / pixelStride else width
                val bitmap = Bitmap.createBitmap(
                    paddedWidth,
                    height,
                    Bitmap.Config.ARGB_8888,
                )
                bitmap.copyPixelsFromBuffer(buffer)
                val scaled = if (rowPadding > 0) {
                    val cropped = Bitmap.createBitmap(bitmap, 0, 0, width, height)
                    if (cropped !== bitmap) bitmap.recycle()
                    cropped
                } else {
                    bitmap
                }
                val baos = ByteArrayOutputStream()
                scaled.compress(Bitmap.CompressFormat.JPEG, 60, baos)
                latestFrameBase64 = Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP)
                scaled.recycle()
            } catch (e: Throwable) {
                Log.w(TAG, "Failed to encode frame: ${e.message}")
            } finally {
                image?.close()
            }
        }
        reader.setOnImageAvailableListener(callback, mainHandler)

        val virtualDisplay = mediaProjection.createVirtualDisplay(
            VIRTUAL_DISPLAY_NAME,
            width,
            height,
            density,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            reader.surface,
            null,
            null,
        )
        this.virtualDisplay = virtualDisplay
        this.imageReader = reader
        Log.d(TAG, "MediaProjection started (${width}x$height @$density dpi)")
        notifyFlutter("started", "MediaProjection active")
    }

    private fun stopProjectionFromApp() {
        val mediaProjection = projection
        releaseProjectionResources()
        try {
            mediaProjection?.stop()
        } catch (e: Throwable) {
            Log.w(TAG, "Failed to stop MediaProjection cleanly: ${e.message}")
        }
    }

    private fun releaseProjectionResources() {
        virtualDisplay?.release()
        virtualDisplay = null
        imageReader?.close()
        imageReader = null
        projection = null
        latestFrameBase64 = null
    }

    private fun stopForegroundCompat() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (e: Throwable) {
            Log.w(TAG, "Failed to stop foreground state: ${e.message}")
        }
    }

    private fun notifyFlutter(event: String, detail: String) {
        try {
            ScreenProjectionBridge.emitEvent(event, detail)
        } catch (e: Throwable) {
            Log.w(TAG, "Failed to push event to Flutter: ${e.message}")
        }
    }
}
