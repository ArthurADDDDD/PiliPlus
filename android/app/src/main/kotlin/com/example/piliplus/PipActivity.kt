package com.example.piliplus

import android.app.Activity
import android.app.ActivityOptions
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.SurfaceTexture
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Surface
import android.view.TextureView
import android.view.ViewGroup

/**
 * 系统原生 PiP 壳：返回键离开视频页时启动，libmpv 的视频输出
 * 从 Flutter 纹理热切换到本 Activity 的 TextureView。
 *
 * Surface 生命周期约定：onSurfaceTextureDestroyed 返回 false，
 * 由 Dart 侧先把 mpv 的 vo/wid 摘掉，再回调 releaseCurrentSurface 释放，
 * 避免 libmpv 向已销毁 Surface 渲染导致崩溃。
 */
class PipActivity : Activity(), TextureView.SurfaceTextureListener {

    companion object {
        private const val EXTRA_WIDTH = "width"
        private const val EXTRA_HEIGHT = "height"
        private const val EXTRA_IS_LIVE = "isLive"
        private const val EXTRA_IS_PLAYING = "isPlaying"

        @JvmStatic
        @Volatile
        var instance: PipActivity? = null

        // 同一时刻只有一个 PiP 壳；surface 状态放 companion，
        // 便于 Activity 已销毁后 Dart 仍能触发释放。
        private val surfaceLock = Any()
        private var surface: Surface? = null
        private var wid: Long = 0L

        private val helperClass: Class<*> by lazy {
            Class.forName("com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper")
        }

        private fun newGlobalRef(obj: Any): Long {
            val method = helperClass.getDeclaredMethod("newGlobalObjectRef", Any::class.java)
            method.isAccessible = true
            return method.invoke(null, obj) as Long
        }

        private fun deleteGlobalRef(ref: Long) {
            val method = helperClass.getDeclaredMethod("deleteGlobalObjectRef", Long::class.java)
            method.isAccessible = true
            method.invoke(null, ref)
        }

        @JvmStatic
        fun launch(context: Context, width: Int, height: Int, isLive: Boolean, isPlaying: Boolean) {
            val intent = Intent(context, PipActivity::class.java)
                .putExtra(EXTRA_WIDTH, width)
                .putExtra(EXTRA_HEIGHT, height)
                .putExtra(EXTRA_IS_LIVE, isLive)
                .putExtra(EXTRA_IS_PLAYING, isPlaying)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val params = AndroidHelper.buildPipParams(context, width, height, isLive, isPlaying)
                context.startActivity(intent, ActivityOptions.makeLaunchIntoPip(params).toBundle())
            } else {
                context.startActivity(intent)
            }
        }

        /** Dart 已把 mpv 输出摘离本 surface 后调用。 */
        @JvmStatic
        fun releaseCurrentSurface() {
            synchronized(surfaceLock) {
                try {
                    surface?.release()
                } catch (_: Throwable) {
                }
                surface = null
                val ref = wid
                wid = 0L
                if (ref != 0L) {
                    // 与 media_kit 的做法一致：延迟删除全局引用，
                    // 消除 libmpv 短时间内仍持有引用的可能。
                    Handler(Looper.getMainLooper()).postDelayed({
                        try {
                            deleteGlobalRef(ref)
                        } catch (_: Throwable) {
                        }
                    }, 5000)
                }
            }
        }
    }

    private var expanded = false
    private var closedNotified = false
    private var isStopped = false
    private var pendingExpand: Runnable? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private fun notifyDart(method: String, args: Any?) {
        android.util.Log.i("PipShellNative", "notifyDart: $method $args (channel=${MainActivity.channel != null})")
        try {
            MainActivity.channel?.invokeMethod(method, args)
        } catch (e: Throwable) {
            android.util.Log.w("PipShellNative", "notifyDart failed", e)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        instance = this
        AndroidHelper.pipShellActivity = this
        AndroidHelper.isPipMode = true

        window.decorView.setBackgroundColor(Color.BLACK)
        val textureView = TextureView(this)
        textureView.surfaceTextureListener = this
        setContentView(
            textureView,
            ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )

        val width = intent.getIntExtra(EXTRA_WIDTH, 16)
        val height = intent.getIntExtra(EXTRA_HEIGHT, 9)
        val isLive = intent.getBooleanExtra(EXTRA_IS_LIVE, false)
        val isPlaying = intent.getBooleanExtra(EXTRA_IS_PLAYING, true)
        val params = AndroidHelper.buildPipParams(this, width, height, isLive, isPlaying)
        setPictureInPictureParams(params)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            // 低版本无法直接以 PiP 形态启动，onCreate 立即收缩
            enterPictureInPictureMode(params)
        }
    }

    override fun onSurfaceTextureAvailable(surfaceTexture: SurfaceTexture, width: Int, height: Int) {
        android.util.Log.i("PipShellNative", "surfaceAvailable ${width}x$height")
        val ref: Long
        synchronized(surfaceLock) {
            val s = Surface(surfaceTexture)
            surface = s
            ref = try {
                newGlobalRef(s)
            } catch (_: Throwable) {
                0L
            }
            wid = ref
        }
        if (ref == 0L) {
            finish()
            return
        }
        notifyDart(
            "PipShell.surfaceCreated",
            mapOf("wid" to ref.toString(), "width" to width, "height" to height),
        )
    }

    override fun onSurfaceTextureSizeChanged(surfaceTexture: SurfaceTexture, width: Int, height: Int) {
        notifyDart("PipShell.surfaceChanged", mapOf("width" to width, "height" to height))
    }

    override fun onSurfaceTextureDestroyed(surfaceTexture: SurfaceTexture): Boolean {
        notifyDart("PipShell.surfaceDestroyed", null)
        // 释放推迟到 Dart 摘离 mpv 输出后（releaseCurrentSurface）
        return false
    }

    override fun onSurfaceTextureUpdated(surfaceTexture: SurfaceTexture) {}

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration?,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        android.util.Log.i(
            "PipShellNative",
            "onPipModeChanged: inPip=$isInPictureInPictureMode finishing=$isFinishing",
        )
        AndroidHelper.isPipMode = isInPictureInPictureMode
        if (!isInPictureInPictureMode) {
            // 离开 PiP 有两种情况：
            //   展开（点全屏）→ Activity 保持前台 resumed，onStop 不会触发；
            //   关闭（拖到 X）→ Activity 被 finish，onStop/onDestroy 触发。
            // 策略：延迟判展开；若期间 onStop 先到（关闭），则取消展开并直接走关闭。
            pendingExpand = Runnable {
                if (!expanded && !closedNotified && !isStopped && !isFinishing) {
                    android.util.Log.i("PipShellNative", "detected EXPAND")
                    expanded = true
                    notifyDart("PipShell.expanded", null)
                    finish()
                    @Suppress("DEPRECATION")
                    overridePendingTransition(0, 0)
                }
            }
            mainHandler.postDelayed(pendingExpand!!, 260)
        }
    }

    override fun onStart() {
        super.onStart()
        isStopped = false
    }

    override fun onStop() {
        super.onStop()
        isStopped = true
        // onStop 在离开 PiP 后触发 = 关闭（拖到 X），而非展开。
        // 取消待定的展开判定，立即走关闭，声音不再残留。
        if (!expanded && !closedNotified) {
            pendingExpand?.let { mainHandler.removeCallbacks(it) }
            pendingExpand = null
            handleClose()
        }
    }

    private fun handleClose() {
        if (closedNotified) return
        closedNotified = true
        android.util.Log.i("PipShellNative", "detected CLOSE")
        // 原生兜底：与「关闭画中画时暂停」一致，即使 Dart 清理失败也保证停止
        if (AndroidHelper.pauseOnPipDismiss) {
            AndroidHelper.sendMediaPause(applicationContext)
        }
        notifyDart("PipShell.closed", null)
    }

    /** 新页面接管播放等场景：静默关闭 PiP 壳，不当作用户关闭处理。 */
    fun finishSilently() {
        expanded = true
        AndroidHelper.isPipMode = false
        pendingExpand?.let { mainHandler.removeCallbacks(it) }
        finish()
    }

    override fun onDestroy() {
        if (instance === this) {
            instance = null
        }
        if (AndroidHelper.pipShellActivity === this) {
            AndroidHelper.pipShellActivity = null
        }
        AndroidHelper.isPipMode = false
        pendingExpand?.let { mainHandler.removeCallbacks(it) }
        if (!expanded && !closedNotified) {
            // 兜底路径（未经过 onStop 的系统回收）
            handleClose()
        }
        // 兜底：Dart 未回调释放时，延迟释放避免泄漏
        Handler(Looper.getMainLooper()).postDelayed({ releaseCurrentSurface() }, 3000)
        super.onDestroy()
    }
}
