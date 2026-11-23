package com.extendpad.android.display

import android.app.Activity
import android.os.Build
import android.util.DisplayMetrics
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager

/** Physical panel facts reported to the Mac (landscape pixel size, density, refresh rate). */
data class PanelInfo(val widthPx: Int, val heightPx: Int, val densityDpi: Int, val xdpi: Double, val refreshHz: Double) {
    fun toMap(): Map<String, Any?> = linkedMapOf(
        "widthPx" to widthPx, "heightPx" to heightPx, "densityDpi" to densityDpi, "xdpi" to xdpi, "refreshHz" to refreshHz,
    )

    companion object {
        @Suppress("DEPRECATION")
        fun read(activity: Activity): PanelInfo {
            val wm = activity.windowManager
            val w: Int
            val h: Int
            if (Build.VERSION.SDK_INT >= 30) {
                val b = wm.maximumWindowMetrics.bounds
                w = b.width(); h = b.height()
            } else {
                val m = DisplayMetrics()
                wm.defaultDisplay.getRealMetrics(m)
                w = m.widthPixels; h = m.heightPixels
            }
            val dm = activity.resources.displayMetrics
            val display = if (Build.VERSION.SDK_INT >= 30) activity.display else wm.defaultDisplay
            val hz = display?.refreshRate?.toDouble() ?: 60.0
            return PanelInfo(maxOf(w, h), minOf(w, h), dm.densityDpi, dm.xdpi.toDouble(), hz)
        }
    }
}

/** Fullscreen immersive mode while streaming; normal system bars otherwise. */
object Immersive {
    @Suppress("DEPRECATION")
    fun enter(activity: Activity) {
        val window = activity.window
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= 28) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let {
                it.hide(WindowInsets.Type.systemBars())
                it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN)
        }
    }

    @Suppress("DEPRECATION")
    fun exit(activity: Activity) {
        val window = activity.window
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(true)
            window.insetsController?.show(WindowInsets.Type.systemBars())
        } else {
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LAYOUT_STABLE
        }
    }
}
