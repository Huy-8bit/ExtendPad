package com.extendpad.android.display

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.util.AttributeSet
import android.view.View

/**
 * Full-screen, non-interactive overlay that draws the Mac cursor bitmap at a given position.
 *
 * Drawing in onDraw (instead of moving/resizing an ImageView) avoids a problem seen on the
 * Huawei MatePad (HarmonyOS 2): an ImageView with a hardware layer stopped rendering after its
 * size changed when the cursor shape changed. Only the old and new cursor rectangles are
 * invalidated, so a 120 Hz position stream costs very little.
 */
class CursorOverlayView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    private var bitmap: Bitmap? = null
    private val dst = RectF()
    private var shown = false
    private val dirty = Rect()

    init {
        isClickable = false
        isFocusable = false
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    /** Place the cursor with its top-left corner at (left, top), size w×h, in this view's pixels. */
    fun show(bmp: Bitmap, left: Float, top: Float, w: Float, h: Float) {
        if (shown && bmp === bitmap && dst.left == left && dst.top == top && dst.width() == w && dst.height() == h) return
        invalidateCursor()
        bitmap = bmp
        dst.set(left, top, left + w, top + h)
        shown = true
        invalidateCursor()
    }

    fun hide() {
        if (!shown) return
        invalidateCursor()
        shown = false
    }

    val isCursorShown: Boolean get() = shown
    val cursorRect: RectF get() = RectF(dst)

    private fun invalidateCursor() {
        if (!shown) return
        dst.roundOut(dirty)
        dirty.inset(-2, -2)
        invalidate(dirty)
    }

    override fun onDraw(canvas: Canvas) {
        val b = bitmap ?: return
        if (shown && !b.isRecycled) canvas.drawBitmap(b, null, dst, paint)
    }
}
