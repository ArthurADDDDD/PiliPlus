package com.example.piliplus

import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.view.WindowManager.LayoutParams
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    companion object {
        /** 供 PipActivity 等非引擎宿主组件向 Dart 发事件。 */
        @JvmStatic
        @Volatile
        var channel: MethodChannel? = null
    }

    private var isActivityResumed = false
    private var methodChannel: MethodChannel? = null
    private var powerSaveRefreshRate = true
    private var pauseOnPipDismiss = true

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "piliplus/android")
        channel = methodChannel
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "setPowerSaveRefreshRate" -> {
                    powerSaveRefreshRate = call.arguments as? Boolean ?: true
                    applyBatteryRefreshRate()
                    result.success(null)
                }
                "setPauseOnPipDismiss" -> {
                    pauseOnPipDismiss = call.arguments as? Boolean ?: true
                    AndroidHelper.pauseOnPipDismiss = pauseOnPipDismiss
                    result.success(null)
                }
                "enterPipShell" -> {
                    val args = call.arguments as? Map<*, *>
                    PipActivity.launch(
                        this,
                        (args?.get("width") as? Int) ?: 16,
                        (args?.get("height") as? Int) ?: 9,
                        (args?.get("isLive") as? Boolean) ?: false,
                        (args?.get("isPlaying") as? Boolean) ?: true,
                    )
                    result.success(null)
                }
                "pipShellReleaseSurface" -> {
                    PipActivity.releaseCurrentSurface()
                    result.success(null)
                }
                "pipShellFinish" -> {
                    PipActivity.instance?.finishSilently()
                    result.success(null)
                }
                "pipShellLog" -> {
                    android.util.Log.i("PipShellDart", call.arguments?.toString() ?: "")
                    result.success(null)
                }
                "setAppIcon" -> {
                    AndroidHelper.setAppIcon((call.arguments as? Boolean) ?: true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (AndroidHelper.isFoldable) {
            AndroidHelper.ToDart.onConfigurationChanged?.run()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        applyBatteryRefreshRate()
    }

    override fun onResume() {
        super.onResume()
        isActivityResumed = true
        applyBatteryRefreshRate()
    }

    override fun onPause() {
        isActivityResumed = false
        super.onPause()
    }

    private fun applyBatteryRefreshRate() {
        val attrs = window.attributes
        if (!powerSaveRefreshRate) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                attrs.preferredDisplayModeId = 0
            }
            attrs.preferredRefreshRate = 0f
            window.attributes = attrs
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            @Suppress("DEPRECATION")
            val currentDisplay = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                display
            } else {
                windowManager.defaultDisplay
            }
            val nativePixels = currentDisplay?.mode?.let {
                it.physicalWidth * it.physicalHeight
            }
            val mode = currentDisplay?.supportedModes
                ?.filter {
                    it.physicalWidth * it.physicalHeight == nativePixels &&
                        it.refreshRate in 59f..61f
                }
                ?.maxByOrNull { it.refreshRate }
            attrs.preferredDisplayModeId = mode?.modeId ?: 0
        }
        attrs.preferredRefreshRate = 60f
        window.attributes = attrs
    }

    override fun onDestroy() {
        stopService(Intent(this, com.ryanheise.audioservice.AudioService::class.java))
        super.onDestroy()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        AndroidHelper.ToDart.onUserLeaveHint?.run()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration?) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        AndroidHelper.isPipMode = isInPictureInPictureMode
        methodChannel?.invokeMethod("onPictureInPictureModeChanged", isInPictureInPictureMode)
        if (!isInPictureInPictureMode) {
            window.decorView.postDelayed({
                if (pauseOnPipDismiss && !AndroidHelper.isPipMode && !isActivityResumed) {
                    pauseFromDismissedPip()
                }
            }, 500)
        }
    }

    private fun pauseFromDismissedPip() {
        AndroidHelper.sendMediaPause(this)
    }
}
