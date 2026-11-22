package com.extendpad.android.input

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View

/** Adapts Android MotionEvents on the video surface to [GestureEngine]. Main thread only. */
class TouchInputController(
    private val view: View,
    private val enabled: () -> Boolean,
    private val onPointer: (GestureEngine.PointerOut) -> Unit,
    private val onInactiveTap: () -> Unit,
) {
    private val engine = GestureEngine(onPointer, slopPx = 12f * view.resources.displayMetrics.density / 1.5f)
    private val handler = Handler(Looper.getMainLooper())
    private val longPressTick = object : Runnable {
        override fun run() {
            engine.checkLongPress(SystemClock.uptimeMillis())
            if (engine.isPending) handler.postDelayed(this, 50)
        }
    }

    fun setScrollScale(s: Float) { engine.scrollScale = s }

    fun attach() {
        view.setOnTouchListener { _, e -> onTouch(e) }
        view.setOnGenericMotionListener { _, e ->
            if (!enabled()) return@setOnGenericMotionListener false
            if (e.actionMasked == MotionEvent.ACTION_HOVER_MOVE) {
                engine.setViewSize(view.width, view.height)
                engine.hover(e.x, e.y); true
            } else false
        }
    }

    private fun onTouch(e: MotionEvent): Boolean {
        if (!enabled()) {
            if (e.actionMasked == MotionEvent.ACTION_UP) onInactiveTap()
            return true
        }
        engine.setViewSize(view.width, view.height)
        val t = SystemClock.uptimeMillis()
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                engine.down(e.x, e.y, t)
                handler.removeCallbacks(longPressTick)
                handler.postDelayed(longPressTick, 50)
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                handler.removeCallbacks(longPressTick)
                if (e.pointerCount == 2) engine.secondPointerDown(centroidX(e), centroidY(e))
            }
            MotionEvent.ACTION_MOVE -> {
                if (e.pointerCount >= 2) engine.scrollMove(centroidX(e), centroidY(e))
                else engine.move(e.x, e.y, t)
            }
            MotionEvent.ACTION_POINTER_UP -> {
                // Leaving 2-finger mode: ignore the rest of this gesture.
                engine.cancel()
            }
            MotionEvent.ACTION_UP -> { handler.removeCallbacks(longPressTick); engine.up(e.x, e.y, t) }
            MotionEvent.ACTION_CANCEL -> { handler.removeCallbacks(longPressTick); engine.cancel() }
        }
        return true
    }

    private fun centroidX(e: MotionEvent): Float { var s = 0f; for (i in 0 until e.pointerCount) s += e.getX(i); return s / e.pointerCount }
    private fun centroidY(e: MotionEvent): Float { var s = 0f; for (i in 0 until e.pointerCount) s += e.getY(i); return s / e.pointerCount }
}
