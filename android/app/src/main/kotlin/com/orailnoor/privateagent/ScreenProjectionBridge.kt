package com.orailnoor.privateagent

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges the native MediaProjection service with Flutter. Dart calls
 * [requestConsent] to obtain a screen-capture intent, which the user must
 * approve once. The result is then forwarded to the foreground service via
 * [startCapture] (which lives in [ScreenCaptureService]).
 */
object ScreenProjectionBridge {
    private const val TAG = "ScreenProjectionBridge"
    private const val METHOD_CHANNEL = "com.privateagent/screen_projection"
    private const val EVENT_CHANNEL = "com.privateagent/screen_projection_events"
    private var eventSink: EventChannel.EventSink? = null

    fun attach(flutterEngine: FlutterEngine, context: Context) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "requestConsent" -> {
                            val mpm = context.getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                                as MediaProjectionManager
                            val intent = mpm.createScreenCaptureIntent()
                            PendingConsentActivity.start(context, intent)
                            result.success(true)
                        }
                        "stop" -> {
                            val reason = call.argument<String>("reason") ?: "requested by Flutter"
                            ScreenCaptureService.stop(context, reason)
                            result.success(true)
                        }
                        "isRunning" -> result.success(ScreenCaptureService.isRunning())
                        "latestFrame" -> result.success(ScreenCaptureService.latestFrame())
                        else -> result.notImplemented()
                    }
                } catch (e: Throwable) {
                    Log.e(TAG, "Bridge error: ${e.message}", e)
                    result.error("BRIDGE_ERROR", e.message, null)
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
    }

    fun emitEvent(type: String, detail: String) {
        try {
            eventSink?.success("$type|$detail")
        } catch (e: Throwable) {
            Log.w(TAG, "Failed to emit event to Flutter: ${e.message}")
        }
    }

    /**
     * Called by [PendingConsentActivity] after the system screen-capture
     * consent dialog completes. Forwards the granted consent directly to
     * [ScreenCaptureService] (so the Dart side does not need to receive the
     * Intent payload over the EventChannel).
     */
    fun handleConsentResult(context: Context, resultCode: Int, data: Intent?) {
        if (resultCode != Activity.RESULT_OK || data == null) {
            eventSink?.success("consent|denied")
            return
        }
        val intent = Intent(context, ScreenCaptureService::class.java).apply {
            action = ScreenCaptureService.ACTION_START
            putExtra(ScreenCaptureService.EXTRA_RESULT_CODE, resultCode)
            putExtra(ScreenCaptureService.EXTRA_RESULT_DATA, data)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
            eventSink?.success("consent|granted")
        } catch (e: Throwable) {
            Log.e(TAG, "Failed to start foreground service: ${e.message}", e)
            eventSink?.success("consent|error|${e.message}")
        }
    }
}

/**
 * Transparent Activity used solely to obtain MediaProjection consent. The
 * system screen-capture dialog requires an Activity context and a callback
 * on `onActivityResult`, so we keep this helper minimal and forward the
 * result straight back to the bridge.
 */
class PendingConsentActivity : Activity() {
    companion object {
        private const val REQUEST_CODE = 0x5050        fun start(context: Context, intent: Intent) {
            val launch = Intent(context, PendingConsentActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            // Pass the screen-capture intent through the activity's own Intent.
            launch.putExtra("inner_intent", intent)
            context.startActivity(launch)
        }
    }

    private var innerIntent: Intent? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        innerIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra("inner_intent", Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra("inner_intent")
        }
        if (innerIntent == null) {
            ScreenProjectionBridge.handleConsentResult(this, RESULT_CANCELED, null)
            finish()
            return
        }
        try {
            startActivityForResult(innerIntent, REQUEST_CODE)
        } catch (e: Throwable) {
            Log.e("PendingConsent", "Failed to start capture: ${e.message}")
            ScreenProjectionBridge.handleConsentResult(this, RESULT_CANCELED, null)
            finish()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CODE) {
            ScreenProjectionBridge.handleConsentResult(this, resultCode, data)
            finish()
        }
    }
}
