package com.extendpad.android.connection

import android.os.SystemClock
import android.util.Log
import com.extendpad.android.transport.Auth
import com.extendpad.android.transport.Frame
import com.extendpad.android.transport.FrameIO
import com.extendpad.android.transport.Payloads
import com.extendpad.android.transport.ProtocolException
import com.extendpad.android.transport.Wire
import com.extendpad.android.transport.bool
import com.extendpad.android.transport.dbl
import com.extendpad.android.transport.int
import com.extendpad.android.transport.str
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.coroutineScope
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean

data class StreamConfig(
    val mode: String, val width: Int, val height: Int, val logicalWidth: Int, val logicalHeight: Int,
    val hiDPI: Boolean, val fps: Int, val bitrate: Int, val quality: String, val preset: String, val inputEnabled: Boolean,
    val localCursor: Boolean = false,
)

sealed class ConnState {
    object Idle : ConnState()
    object NotPaired : ConnState()
    data class WaitingForMac(val attempt: Int, val detail: String?) : ConnState()
    object Handshaking : ConnState()
    data class Connected(val config: StreamConfig?, val serverName: String) : ConnState()
    data class Rejected(val code: String, val message: String) : ConnState()
}

class ClientInfo(val device: Map<String, Any?>, val display: Map<String, Any?>, val decoder: Map<String, Any?>, val appVersion: String)

interface SessionListener {
    fun onState(state: ConnState)
    /** Network thread. */
    fun onVideoConfig(cfg: Payloads.VideoConfig)
    /** Network thread. */
    fun onVideoFrame(frame: Payloads.VideoFrame, receivedNanos: Long)
    fun onRemoteError(code: String, message: String)
    fun statsSnapshot(): Map<String, Any?>
    /** Control thread: Mac cursor position (drawn locally on the tablet). */
    fun onCursorPos(pos: Payloads.CursorPos) {}
    /** Control thread: Mac cursor shape changed. */
    fun onCursorImage(img: Payloads.CursorImage) {}
}

class AuthRejectedException(val code: String, msg: String) : IOException(msg)

/**
 * Connects to the Mac through the ADB reverse tunnel (127.0.0.1:<port> on the tablet), performs the
 * authenticated handshake on a control and a video socket, and keeps reconnecting with back-off.
 */
class SessionClient(
    private val listener: SessionListener,
    private val infoProvider: () -> ClientInfo,
    private val tokenProvider: () -> String?,
    private val portProvider: () -> Int,
) {
    companion object {
        private const val TAG = "ExtendPad.Session"
        const val DETAIL_NO_TUNNEL = "no_tunnel"
        const val DETAIL_NO_SERVER = "no_server"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var loopJob: Job? = null
    @Volatile private var current: LiveSession? = null
    @Volatile var paused = false
        private set
    @Volatile var state: ConnState = ConnState.Idle
        private set
    @Volatile var rttMs = 0.0
        private set
    @Volatile private var wakeUp = false

    val isRunning: Boolean get() = loopJob?.isActive == true

    private fun setState(s: ConnState) {
        if (s == state) return
        state = s
        listener.onState(s)
    }

    fun start() {
        if (loopJob?.isActive == true) return
        loopJob = scope.launch { runLoop() }
    }

    /** Ends the session and stops reconnecting. */
    fun stop(reason: String = "user disconnected") {
        current?.let { it.trySend(FrameIO.encodeJson(Wire.BYE, mapOf("reason" to reason))); it.closeSoon() }
        loopJob?.cancel()
        loopJob = null
        current = null
        setState(ConnState.Idle)
    }

    /** Skip the current back-off delay (new token arrived / user tapped Retry). */
    fun reconnectNow() {
        wakeUp = true
        if (!isRunning) start()
    }

    fun shutdown() { stop("app closed"); scope.cancel() }

    fun setPaused(p: Boolean) {
        paused = p
        current?.trySend(FrameIO.encode(if (p) Wire.STREAM_PAUSE else Wire.STREAM_RESUME))
    }

    fun requestKeyframe() { current?.trySend(FrameIO.encode(Wire.KEYFRAME_REQUEST)) }
    fun sendFrameAck(frameId: Int, receiveToRenderMicros: Int) {
        current?.trySend(FrameIO.encode(Wire.FRAME_ACK, Payloads.frameAck(frameId, receiveToRenderMicros)))
    }
    fun sendPointer(payload: ByteArray) { current?.trySend(FrameIO.encode(Wire.INPUT_POINTER, payload)) }
    fun sendSettings(map: Map<String, Any?>) { current?.trySend(FrameIO.encodeJson(Wire.SETTINGS_REQUEST, map)) }

    private suspend fun runLoop() {
        var attempt = 0
        var lastDetail: String? = null
        while (scope.isActive) {
            val token = tokenProvider()
            if (!Auth.isValidToken(token)) {
                setState(ConnState.NotPaired)
                sleepInterruptible(1000)
                continue
            }
            if (state !is ConnState.Rejected || attempt > 0) setState(ConnState.WaitingForMac(attempt, lastDetail))
            var backoff = when { attempt <= 1 -> 500L; attempt <= 4 -> 1000L; else -> 2000L }
            try {
                runSession(token!!)
                attempt = 0
                lastDetail = "session ended"
            } catch (e: CancellationException) {
                throw e
            } catch (e: AuthRejectedException) {
                Log.w(TAG, "rejected: ${e.code} ${e.message}")
                setState(ConnState.Rejected(e.code, e.message ?: ""))
                lastDetail = e.message
                backoff = 3000
                attempt++
            } catch (e: java.net.ConnectException) {
                // Nothing listens on 127.0.0.1:<port>: the adb reverse tunnel is not set up (yet).
                lastDetail = DETAIL_NO_TUNNEL
                attempt++
            } catch (e: IOException) {
                // The tunnel accepted us and then closed: adbd is forwarding but the Mac app isn't listening.
                lastDetail = if (state !is ConnState.Connected && state !is ConnState.Handshaking) DETAIL_NO_SERVER
                             else (e.message ?: e.javaClass.simpleName)
                if (attempt % 10 == 0) Log.i(TAG, "connect attempt $attempt: ${e.message}")
                attempt++
            } catch (e: Exception) {
                lastDetail = e.message ?: e.javaClass.simpleName
                if (attempt % 10 == 0) Log.i(TAG, "connect attempt $attempt: $lastDetail")
                attempt++
            } finally {
                current = null
            }
            sleepInterruptible(backoff)
        }
    }

    private suspend fun sleepInterruptible(ms: Long) {
        var left = ms
        while (left > 0 && !wakeUp) { delay(minOf(50L, left)); left -= 50 }
        wakeUp = false
    }

    private fun openSocket(port: Int): Socket {
        val s = Socket()
        s.tcpNoDelay = true
        s.keepAlive = true
        s.receiveBufferSize = 1 shl 20
        // Only ever the loopback address: traffic goes through adbd → USB → Mac, never Wi‑Fi.
        s.connect(InetSocketAddress("127.0.0.1", port), 2000)
        s.soTimeout = 5000
        return s
    }

    /** Runs one full session; returns normally on a graceful end, throws on failure. */
    private suspend fun runSession(token: String) {
        val port = portProvider()
        val control = openSocket(port)
        val live = LiveSession(control)
        current = live
        try {
            val cin = DataInputStream(BufferedInputStream(control.getInputStream(), 64 * 1024))
            val cout = BufferedOutputStream(control.getOutputStream(), 16 * 1024)
            val info = infoProvider()
            val (sessionId, serverName) = handshake("control", cin, cout, token, info, null)
            setState(ConnState.Handshaking)
            control.soTimeout = 0
            live.serverName = serverName

            val video = openSocket(port)
            live.video = video
            val vin = DataInputStream(BufferedInputStream(video.getInputStream(), 512 * 1024))
            val vout = BufferedOutputStream(video.getOutputStream())
            handshake("video", vin, vout, token, info, sessionId)
            video.soTimeout = 0
            Log.i(TAG, "session $sessionId established with $serverName")
            setState(ConnState.Connected(null, serverName))
            if (paused) live.trySend(FrameIO.encode(Wire.STREAM_PAUSE))

            coroutineScope {
                launch { // writer: the only thread that writes the control socket
                    try { for (bytes in live.outbox) FrameIO.write(cout, bytes) }
                    catch (e: IOException) { live.fail("write: ${e.message}") }
                    finally { live.close() }
                }
                launch { // heartbeat + stats
                    var id = 0L
                    try {
                        while (!live.closed.get()) {
                            delay(1000)
                            live.trySend(FrameIO.encode(Wire.PING, Payloads.ping(++id, nowMicros())))
                            live.trySend(FrameIO.encodeJson(Wire.STATS, listener.statsSnapshot()))
                            if (SystemClock.elapsedRealtime() - live.lastReceive > 5000) {
                                live.fail("Mac stopped responding (heartbeat timeout)"); break
                            }
                        }
                    } finally { live.close() }
                }
                launch { // control reader
                    try {
                        while (!live.closed.get()) {
                            val f = FrameIO.read(cin, Wire.MAX_CONTROL)
                            live.lastReceive = SystemClock.elapsedRealtime()
                            handleControl(live, f)
                        }
                    } catch (e: IOException) { live.fail(e.message ?: "control closed") }
                    finally { live.close() }
                }
                launch { // video reader
                    try {
                        while (!live.closed.get()) {
                            val f = FrameIO.read(vin, Wire.MAX_VIDEO)
                            val now = System.nanoTime()
                            when (f.type) {
                                Wire.VIDEO_CONFIG -> Payloads.parseVideoConfig(f.payload)?.let { listener.onVideoConfig(it) }
                                    ?: throw ProtocolException("malformed VIDEO_CONFIG")
                                Wire.VIDEO_FRAME -> Payloads.parseVideoFrame(f.payload)?.let { listener.onVideoFrame(it, now) }
                                    ?: throw ProtocolException("malformed VIDEO_FRAME")
                                else -> {} // ignore unknown types
                            }
                        }
                    } catch (e: IOException) { live.fail(e.message ?: "video closed") }
                    finally { live.close() }
                }
            }
            live.failure?.let { if (!live.graceful) throw IOException(it) }
        } finally {
            live.close()
        }
    }

    private fun handleControl(live: LiveSession, f: Frame) {
        when (f.type) {
            Wire.PING -> Payloads.parsePing(f.payload)?.let {
                live.trySend(FrameIO.encode(Wire.PONG, Payloads.pong(it.id, it.micros, nowMicros())))
            }
            Wire.PONG -> Payloads.parsePong(f.payload)?.let {
                val rtt = (nowMicros() - it.echoed) / 1000.0
                if (rtt in 0.0..10_000.0) rttMs = if (rttMs == 0.0) rtt else rttMs * 0.8 + rtt * 0.2
            }
            Wire.STREAM_CONFIG -> {
                val j = f.json()
                val cfg = StreamConfig(
                    mode = j.str("mode") ?: "extend",
                    width = j.int("width") ?: 0, height = j.int("height") ?: 0,
                    logicalWidth = j.int("logicalWidth") ?: 0, logicalHeight = j.int("logicalHeight") ?: 0,
                    hiDPI = j.bool("hiDPI") ?: false, fps = j.int("fps") ?: 0, bitrate = j.int("bitrate") ?: 0,
                    quality = j.str("quality") ?: "balanced", preset = j.str("preset") ?: "native",
                    inputEnabled = j.bool("inputEnabled") ?: false,
                    localCursor = j.bool("localCursor") ?: false,
                )
                setState(ConnState.Connected(cfg, live.serverName))
            }
            Wire.CURSOR_POS -> Payloads.parseCursorPos(f.payload)?.let { listener.onCursorPos(it) }
            Wire.CURSOR_IMAGE -> Payloads.parseCursorImage(f.payload)?.let { listener.onCursorImage(it) }
            Wire.ERROR -> {
                val j = f.json()
                listener.onRemoteError(j.str("code") ?: "error", j.str("message") ?: "")
            }
            Wire.BYE -> {
                live.graceful = true
                live.fail("Mac ended the session: ${f.json().str("reason") ?: ""}")
            }
            else -> {} // forward compatible
        }
    }

    /** HELLO → CHALLENGE → AUTH → ACCEPT; returns (sessionId, serverName). */
    private fun handshake(channel: String, input: DataInputStream, out: BufferedOutputStream, token: String,
                          info: ClientInfo, sessionId: String?): Pair<String, String> {
        val clientNonce = Auth.randomHex(16)
        val hello = linkedMapOf<String, Any?>(
            "magic" to Wire.MAGIC, "protocol" to Wire.VERSION, "channel" to channel,
            "clientNonce" to clientNonce, "appVersion" to info.appVersion,
        )
        if (channel == "control") {
            hello["device"] = info.device; hello["display"] = info.display; hello["decoder"] = info.decoder
        } else hello["sessionId"] = sessionId
        FrameIO.write(out, FrameIO.encodeJson(Wire.HELLO, hello))

        val ch = FrameIO.read(input, Wire.MAX_CONTROL)
        if (ch.type == Wire.REJECT) { val j = ch.json(); throw AuthRejectedException(j.str("code") ?: "?", j.str("message") ?: "rejected") }
        if (ch.type != Wire.CHALLENGE) throw ProtocolException("expected CHALLENGE, got ${ch.type}")
        val cj = ch.json()
        val serverNonce = cj.str("serverNonce") ?: throw ProtocolException("missing serverNonce")
        if (serverNonce.length != 32 || Auth.hexDecode(serverNonce) == null) throw ProtocolException("bad serverNonce")
        val mac = Auth.hmacHex(token, "client", channel, clientNonce, serverNonce) ?: throw ProtocolException("bad token")
        FrameIO.write(out, FrameIO.encodeJson(Wire.AUTH, mapOf("mac" to mac)))

        val acc = FrameIO.read(input, Wire.MAX_CONTROL)
        if (acc.type == Wire.REJECT) { val j = acc.json(); throw AuthRejectedException(j.str("code") ?: "?", j.str("message") ?: "rejected") }
        if (acc.type != Wire.ACCEPT) throw ProtocolException("expected ACCEPT, got ${acc.type}")
        val aj = acc.json()
        val expected = Auth.hmacHex(token, "server", channel, clientNonce, serverNonce)!!
        val proof = aj.str("serverProof") ?: ""
        if (!Auth.constantTimeEquals(expected, proof.lowercase())) throw AuthRejectedException("server_proof", "The Mac could not prove it knows the pairing token")
        return Pair(aj.str("sessionId") ?: sessionId ?: "", cj.str("serverName") ?: "Mac")
    }

    private fun nowMicros(): Long = SystemClock.elapsedRealtimeNanos() / 1000

    /** State of one connected session; all sockets are closed together. */
    private class LiveSession(val control: Socket) {
        @Volatile var video: Socket? = null
        @Volatile var lastReceive = SystemClock.elapsedRealtime()
        @Volatile var failure: String? = null
        @Volatile var graceful = false
        @Volatile var serverName = "Mac"
        val closed = AtomicBoolean(false)
        /** Bounded outbox: control messages are tiny; if 512 are queued the link is dead anyway. */
        val outbox = Channel<ByteArray>(512)

        fun trySend(bytes: ByteArray) { if (!closed.get()) outbox.trySend(bytes) }
        fun fail(msg: String) { if (failure == null) failure = msg; close() }
        fun closeSoon() { Thread { Thread.sleep(150); close() }.start() }
        fun close() {
            if (!closed.compareAndSet(false, true)) return
            outbox.close()
            try { control.close() } catch (_: IOException) {}
            try { video?.close() } catch (_: IOException) {}
        }
    }
}
