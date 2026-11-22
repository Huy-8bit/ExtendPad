package com.extendpad.android.input

/**
 * Turns touches on the video surface into mouse-style events for the Mac (pure logic, unit tested).
 *
 *  - tap                 → left click
 *  - drag (past slop)    → left button held + move
 *  - long press (still)  → right click
 *  - two-finger drag     → scroll (content follows fingers)
 *  - stylus hover        → move pointer
 *
 * Coordinates are view-relative pixels on the (letterbox-free) video surface; output positions are
 * normalised to 0..65535 across the surface, so scaling/HiDPI/arrangement are handled on the Mac.
 */
class GestureEngine(
    private val sink: (PointerOut) -> Unit,
    private val slopPx: Float = 14f,
    private val longPressMs: Long = 550,
) {
    data class PointerOut(val action: Int, val button: Int, val x: Int, val y: Int, val scrollX: Int = 0, val scrollY: Int = 0)

    companion object {
        const val MOVE = 0; const val DOWN = 1; const val UP = 2; const val SCROLL = 3; const val CANCEL = 4
        const val LEFT = 0; const val RIGHT = 1
        fun normalize(v: Float, size: Int): Int =
            if (size <= 1) 0 else ((v / (size - 1)) * 65535f).toInt().coerceIn(0, 65535)
    }

    private enum class State { IDLE, PENDING, DRAGGING, SCROLLING, LONG_PRESSED }

    private var state = State.IDLE
    private var viewW = 1
    private var viewH = 1
    private var startX = 0f; private var startY = 0f; private var startT = 0L
    private var lastX = 0f; private var lastY = 0f
    private var centroidX = 0f; private var centroidY = 0f
    private var accX = 0f; private var accY = 0f
    /** Tablet pixels → Mac points for scrolling. */
    var scrollScale = 1f

    fun setViewSize(w: Int, h: Int) { viewW = maxOf(1, w); viewH = maxOf(1, h) }

    private fun nx(x: Float) = normalize(x, viewW)
    private fun ny(y: Float) = normalize(y, viewH)

    fun down(x: Float, y: Float, t: Long) {
        state = State.PENDING
        startX = x; startY = y; startT = t; lastX = x; lastY = y
        sink(PointerOut(MOVE, LEFT, nx(x), ny(y)))
    }

    fun move(x: Float, y: Float, t: Long) {
        lastX = x; lastY = y
        when (state) {
            State.PENDING -> {
                if (dist(x - startX, y - startY) > slopPx) {
                    sink(PointerOut(DOWN, LEFT, nx(startX), ny(startY)))
                    sink(PointerOut(MOVE, LEFT, nx(x), ny(y)))
                    state = State.DRAGGING
                } else checkLongPress(t)
            }
            State.DRAGGING -> sink(PointerOut(MOVE, LEFT, nx(x), ny(y)))
            else -> {}
        }
    }

    /** Called from a timer while a finger is down and still. */
    fun checkLongPress(t: Long) {
        if (state == State.PENDING && t - startT >= longPressMs) {
            sink(PointerOut(DOWN, RIGHT, nx(startX), ny(startY)))
            sink(PointerOut(UP, RIGHT, nx(startX), ny(startY)))
            state = State.LONG_PRESSED
        }
    }

    fun up(x: Float, y: Float, t: Long) {
        when (state) {
            State.PENDING -> {
                checkLongPress(t)
                if (state == State.PENDING) {
                    sink(PointerOut(DOWN, LEFT, nx(startX), ny(startY)))
                    sink(PointerOut(UP, LEFT, nx(startX), ny(startY)))
                }
            }
            State.DRAGGING -> sink(PointerOut(UP, LEFT, nx(x), ny(y)))
            else -> {}
        }
        state = State.IDLE
    }

    /** A second finger landed: switch to scrolling. */
    fun secondPointerDown(cx: Float, cy: Float) {
        if (state == State.DRAGGING) sink(PointerOut(UP, LEFT, nx(lastX), ny(lastY)))
        state = State.SCROLLING
        centroidX = cx; centroidY = cy; accX = 0f; accY = 0f
    }

    fun scrollMove(cx: Float, cy: Float) {
        if (state != State.SCROLLING) return
        accX += (cx - centroidX) * scrollScale
        accY += (cy - centroidY) * scrollScale
        centroidX = cx; centroidY = cy
        val sx = accX.toInt(); val sy = accY.toInt()
        if (sx != 0 || sy != 0) {
            accX -= sx; accY -= sy
            sink(PointerOut(SCROLL, LEFT, nx(cx), ny(cy), sx, sy))
        }
    }

    /** All fingers lifted after a multi-finger gesture, or the system cancelled the gesture. */
    fun cancel() {
        if (state == State.DRAGGING) sink(PointerOut(CANCEL, LEFT, nx(lastX), ny(lastY)))
        state = State.IDLE
    }

    fun hover(x: Float, y: Float) {
        if (state == State.IDLE) sink(PointerOut(MOVE, LEFT, nx(x), ny(y)))
    }

    val isPending: Boolean get() = state == State.PENDING

    private fun dist(dx: Float, dy: Float) = kotlin.math.sqrt(dx * dx + dy * dy)
}
