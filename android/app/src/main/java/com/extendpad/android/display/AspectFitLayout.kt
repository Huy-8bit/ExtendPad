package com.extendpad.android.display

import android.content.Context
import android.util.AttributeSet
import android.widget.FrameLayout

/**
 * Sizes its single child (the SurfaceView) to the largest rectangle with the stream's aspect ratio
 * that fits, centred — letterboxing instead of stretching.
 */
class AspectFitLayout @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : FrameLayout(context, attrs) {
    private var videoW = 0
    private var videoH = 0

    fun setVideoSize(w: Int, h: Int) {
        if (w == videoW && h == videoH) return
        videoW = w; videoH = h
        requestLayout()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val w = MeasureSpec.getSize(widthMeasureSpec)
        val h = MeasureSpec.getSize(heightMeasureSpec)
        setMeasuredDimension(w, h)
        val (cw, ch) = fit(w, h, videoW, videoH)
        for (i in 0 until childCount) {
            getChildAt(i).measure(MeasureSpec.makeMeasureSpec(cw, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(ch, MeasureSpec.EXACTLY))
        }
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        val w = right - left; val h = bottom - top
        for (i in 0 until childCount) {
            val c = getChildAt(i)
            val x = (w - c.measuredWidth) / 2
            val y = (h - c.measuredHeight) / 2
            c.layout(x, y, x + c.measuredWidth, y + c.measuredHeight)
        }
    }

    companion object {
        /** Pure aspect-fit computation (unit tested). */
        fun fit(containerW: Int, containerH: Int, videoW: Int, videoH: Int): Pair<Int, Int> {
            if (videoW <= 0 || videoH <= 0 || containerW <= 0 || containerH <= 0) return Pair(containerW, containerH)
            val scale = minOf(containerW.toDouble() / videoW, containerH.toDouble() / videoH)
            return Pair((videoW * scale).toInt().coerceAtMost(containerW), (videoH * scale).toInt().coerceAtMost(containerH))
        }
    }
}
