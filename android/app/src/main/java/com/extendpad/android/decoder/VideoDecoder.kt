package com.extendpad.android.decoder

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface
import com.extendpad.android.transport.AnnexB
import com.extendpad.android.transport.Payloads
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Hardware H.264 decoding straight into a Surface (no Bitmaps, no CPU copies of pixels).
 *
 * - Bounded input queue (8 access units). On overflow the queue is flushed, frames are skipped
 *   until the next IDR and a keyframe is requested — old frames never pile up.
 * - Output buffers are released to the Surface immediately (render as soon as decoded).
 * - Reconfigures on VIDEO_CONFIG changes and when the Surface is recreated.
 * - Any codec error → release, recreate, request keyframe.
 */
class VideoDecoder(private val callbacks: Callbacks) {
    interface Callbacks {
        fun requestKeyframe(reason: String)
        fun onFrameRendered(frameId: Int, receiveToRenderMicros: Int)
        fun onDecoderInfo(name: String, lowLatency: Boolean)
        fun onVideoSize(width: Int, height: Int)
    }

    companion object {
        private const val TAG = "ExtendPad.Decoder"
        private const val MIME = MediaFormat.MIMETYPE_VIDEO_AVC
        const val QUEUE_CAPACITY = 8
    }

    private class Packet(val frameId: Int, val key: Boolean, val data: ByteArray, val off: Int, val len: Int, val receivedNanos: Long)

    private val queue = ArrayBlockingQueue<Packet>(QUEUE_CAPACITY)
    private val lock = ReentrantLock()
    private var codec: MediaCodec? = null
    private var surface: Surface? = null
    private var config: Payloads.VideoConfig? = null
    private var configuredFor: Payloads.VideoConfig? = null
    @Volatile private var needsConfigure = false
    @Volatile private var waitForKeyframe = true
    @Volatile private var running = false
    private var inputThread: Thread? = null
    private var outputThread: Thread? = null
    private var generation = 0

    // Receive time per frame (ring buffer indexed by frameId) for receive→render latency.
    private val recvTimes = LongArray(256)

    // Stats (read by the UI / sent to the Mac)
    @Volatile var decodedFrames = 0L; private set
    @Volatile var droppedFrames = 0L; private set
    @Volatile var lastDecodeMs = 0.0; private set
    @Volatile var codecName = ""; private set
    @Volatile var lowLatencyActive = false; private set
    val queueDepth: Int get() = queue.size

    fun start() {
        if (running) return
        running = true
        inputThread = Thread({ inputLoop() }, "ep-decoder-in").apply { priority = Thread.MAX_PRIORITY; start() }
    }

    fun stop() {
        running = false
        inputThread?.interrupt()
        inputThread?.join(500)
        inputThread = null
        releaseCodec()
        queue.clear()
    }

    /** Main thread: Surface created/changed (non-null) or destroyed (null). Releases synchronously on null. */
    fun setSurface(s: Surface?) {
        lock.withLock {
            if (s == null) {
                releaseCodecLocked()
                surface = null
            } else if (s !== surface) {
                releaseCodecLocked()
                surface = s
                needsConfigure = config != null
            }
        }
        if (s != null && config != null) callbacks.requestKeyframe("surface recreated")
    }

    /** Network thread. */
    fun onConfig(cfg: Payloads.VideoConfig) {
        val changed = lock.withLock {
            val old = config
            val same = old != null && old.width == cfg.width && old.height == cfg.height && old.csd.contentEquals(cfg.csd)
            if (!same) { config = cfg; needsConfigure = true; waitForKeyframe = true }
            !same
        }
        if (changed) {
            queue.clear()
            Log.i(TAG, "stream config ${cfg.width}x${cfg.height} profile=${cfg.profileIdc} level=${cfg.levelIdc}")
            callbacks.onVideoSize(cfg.width, cfg.height)
        }
    }

    /** Network thread. Never blocks. */
    fun onFrame(f: Payloads.VideoFrame, receivedNanos: Long) {
        if (waitForKeyframe && !f.keyframe) { droppedFrames++; return }
        if (f.keyframe) waitForKeyframe = false
        val p = Packet(f.frameId, f.keyframe, f.data, f.offset, f.length, receivedNanos)
        if (!queue.offer(p)) {
            // Decoder can't keep up: discard everything queued, resync on the next IDR.
            droppedFrames += queue.size + 1
            queue.clear()
            waitForKeyframe = true
            callbacks.requestKeyframe("decoder queue overflow")
        }
    }

    private fun inputLoop() {
        while (running) {
            try {
                if (needsConfigure) configureIfPossible()
                val p = queue.poll(20, TimeUnit.MILLISECONDS) ?: continue
                lock.withLock {
                    val c = codec
                    if (c == null) { droppedFrames++; waitForKeyframe = true; return@withLock }
                    var idx = -1
                    for (attempt in 0 until 5) {
                        idx = c.dequeueInputBuffer(10_000)
                        if (idx >= 0) break
                    }
                    if (idx < 0) {
                        droppedFrames++
                        waitForKeyframe = true
                        queue.clear()
                        callbacks.requestKeyframe("no decoder input buffer")
                        return@withLock
                    }
                    val buf = c.getInputBuffer(idx) ?: return@withLock
                    buf.clear()
                    if (p.len > buf.capacity()) {
                        c.queueInputBuffer(idx, 0, 0, 0, 0)
                        droppedFrames++; waitForKeyframe = true
                        callbacks.requestKeyframe("access unit larger than input buffer")
                        return@withLock
                    }
                    buf.put(p.data, p.off, p.len)
                    recvTimes[p.frameId and 0xff] = p.receivedNanos
                    // presentationTimeUs carries the frame id (monotonic) so output → ack mapping is exact.
                    c.queueInputBuffer(idx, 0, p.len, p.frameId.toLong() and 0xffffffffL, 0)
                }
            } catch (e: InterruptedException) {
                break
            } catch (e: Exception) {
                Log.w(TAG, "decoder input error: $e")
                recoverFromError("input: ${e.javaClass.simpleName}")
            }
        }
    }

    private fun outputLoop(c: MediaCodec, gen: Int) {
        val info = MediaCodec.BufferInfo()
        while (running && gen == generation) {
            try {
                val idx = c.dequeueOutputBuffer(info, 10_000)
                if (idx >= 0) {
                    val frameId = (info.presentationTimeUs and 0xffffffffL).toInt()
                    c.releaseOutputBuffer(idx, info.size > 0)
                    if (info.size > 0) {
                        decodedFrames++
                        val recv = recvTimes[frameId and 0xff]
                        val r2r = if (recv > 0) ((System.nanoTime() - recv) / 1000).coerceIn(0, Int.MAX_VALUE.toLong()).toInt() else 0
                        lastDecodeMs = r2r / 1000.0
                        callbacks.onFrameRendered(frameId, r2r)
                    }
                } else if (idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    Log.i(TAG, "output format ${c.outputFormat}")
                }
            } catch (e: IllegalStateException) {
                if (gen != generation || !running) break
                Log.w(TAG, "decoder output error: $e")
                recoverFromError("output: ${e.javaClass.simpleName}")
                break
            }
        }
    }

    private fun configureIfPossible() {
        lock.withLock {
            val cfg = config ?: return
            val s = surface ?: return
            if (!s.isValid) return
            releaseCodecLocked()
            needsConfigure = false
            val (sps, pps) = AnnexB.splitParameterSets(cfg.csd) ?: run {
                Log.w(TAG, "VIDEO_CONFIG lacks SPS/PPS"); return
            }
            val caps = DecoderCaps.candidates()
            for (info in caps) {
                for (withVendorKeys in listOf(true, false)) {
                    var c: MediaCodec? = null
                    try {
                        c = MediaCodec.createByCodecName(info.name)
                        val f = buildFormat(cfg, sps, pps, info.name, withVendorKeys, info)
                        c.configure(f, s, null, 0)
                        c.start()
                        codec = c
                        configuredFor = cfg
                        codecName = info.name
                        lowLatencyActive = f.containsKey("low-latency")
                        generation++
                        val gen = generation
                        outputThread = Thread({ outputLoop(c, gen) }, "ep-decoder-out").apply { priority = Thread.MAX_PRIORITY; start() }
                        waitForKeyframe = true
                        Log.i(TAG, "decoder ${info.name} started ${cfg.width}x${cfg.height} lowLatency=$lowLatencyActive vendorKeys=$withVendorKeys")
                        callbacks.onDecoderInfo(info.name, lowLatencyActive)
                        callbacks.requestKeyframe("decoder started")
                        return
                    } catch (e: Exception) {
                        Log.w(TAG, "configure ${info.name} (vendorKeys=$withVendorKeys) failed: $e")
                        try { c?.release() } catch (_: Exception) {}
                    }
                }
            }
            Log.e(TAG, "no decoder could be configured")
        }
    }

    private fun buildFormat(cfg: Payloads.VideoConfig, sps: ByteArray, pps: ByteArray, name: String,
                            vendorKeys: Boolean, info: android.media.MediaCodecInfo): MediaFormat {
        val f = MediaFormat.createVideoFormat(MIME, cfg.width, cfg.height)
        f.setByteBuffer("csd-0", java.nio.ByteBuffer.wrap(sps))
        f.setByteBuffer("csd-1", java.nio.ByteBuffer.wrap(pps))
        f.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, maxOf(cfg.width * cfg.height, 1 shl 20))
        f.setInteger(MediaFormat.KEY_PRIORITY, 0) // real-time
        if (Build.VERSION.SDK_INT >= 30) {
            try {
                val caps = info.getCapabilitiesForType(MIME)
                if (caps.isFeatureSupported(android.media.MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)) {
                    f.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                }
            } catch (_: Exception) {}
        }
        if (vendorKeys) {
            val n = name.lowercase()
            when {
                n.contains("qcom") || n.contains("qti") -> {
                    f.setInteger("vendor.qti-ext-dec-picture-order.enable", 1)
                    f.setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
                }
                n.contains("hisi") || n.contains("kirin") -> {
                    f.setInteger("vendor.hisi-ext-low-latency-video-dec.video-scene-for-low-latency-req", 1)
                    f.setInteger("vendor.hisi-ext-low-latency-video-dec.video-scene-for-low-latency-rdy", -1)
                }
                n.contains("mtk") || n.contains("mediatek") -> {
                    f.setInteger("vendor.mtk.vdec.cpu.boost.mode.value", 1)
                }
                n.contains("exynos") -> {
                    f.setInteger("vendor.rtc-ext-dec-low-latency.enable", 1)
                }
            }
        }
        return f
    }

    private fun recoverFromError(reason: String) {
        lock.withLock {
            releaseCodecLocked()
            needsConfigure = config != null && surface != null
            waitForKeyframe = true
        }
        queue.clear()
        callbacks.requestKeyframe("decoder error ($reason)")
    }

    private fun releaseCodec() = lock.withLock { releaseCodecLocked() }

    private fun releaseCodecLocked() {
        val c = codec ?: return
        codec = null
        configuredFor = null
        generation++
        try { c.stop() } catch (_: Exception) {}
        try { c.release() } catch (_: Exception) {}
        val t = outputThread
        if (t != null && t !== Thread.currentThread()) t.join(200)
        outputThread = null
    }
}
