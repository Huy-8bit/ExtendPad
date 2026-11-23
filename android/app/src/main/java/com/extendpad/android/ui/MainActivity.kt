package com.extendpad.android.ui

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.widget.Button
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.widget.CheckBox
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import com.extendpad.android.BuildConfig
import com.extendpad.android.R
import com.extendpad.android.connection.ClientInfo
import com.extendpad.android.connection.ConnState
import com.extendpad.android.connection.SessionClient
import com.extendpad.android.connection.SessionListener
import com.extendpad.android.connection.StreamConfig
import com.extendpad.android.decoder.DecoderCaps
import com.extendpad.android.decoder.VideoDecoder
import com.extendpad.android.display.AspectFitLayout
import com.extendpad.android.display.CursorOverlayView
import com.extendpad.android.display.Immersive
import com.extendpad.android.display.PanelInfo
import com.extendpad.android.input.TouchInputController
import com.extendpad.android.settings.Prefs
import com.extendpad.android.transport.Auth
import com.extendpad.android.transport.Payloads

class MainActivity : Activity(), SessionListener, VideoDecoder.Callbacks, SurfaceHolder.Callback {
    companion object {
        private const val TAG = "ExtendPad"
        const val ACTION_CONNECT = "com.extendpad.action.CONNECT"
        private const val BACKGROUND_DISCONNECT_MS = 60_000L
        private val QUALITIES = listOf("performance", "balanced", "quality")
        private val PRESETS = listOf("native", "comfortable", "large", "performance")
    }

    private lateinit var prefs: Prefs
    private lateinit var client: SessionClient
    private lateinit var decoder: VideoDecoder
    private lateinit var panel: PanelInfo
    private lateinit var caps: DecoderCaps
    private lateinit var touch: TouchInputController
    private val main = Handler(Looper.getMainLooper())

    private lateinit var videoContainer: AspectFitLayout
    private lateinit var surfaceView: SurfaceView
    private lateinit var statusScreen: View
    private lateinit var statusTitle: TextView
    private lateinit var statusDetail: TextView
    private lateinit var transportState: TextView
    private lateinit var progress: ProgressBar
    private lateinit var statsOverlay: TextView
    private lateinit var controlHandle: ImageButton
    private lateinit var controlPanel: LinearLayout
    private lateinit var btnQuality: Button
    private lateinit var btnScaling: Button
    private lateinit var btnTouch: Button
    private lateinit var btnStats: Button
    private lateinit var cursorView: CursorOverlayView

    // Local cursor state (written by the control thread, applied on the main thread once per post).
    @Volatile private var cursorX = 0
    @Volatile private var cursorY = 0
    @Volatile private var cursorVisible = false
    @Volatile private var cursorImage: Payloads.CursorImage? = null
    private var cursorBitmap: Bitmap? = null
    private val cursorPosted = java.util.concurrent.atomic.AtomicBoolean(false)
    private val applyCursor = Runnable { cursorPosted.set(false); updateCursorView() }

    @Volatile private var streamConfig: StreamConfig? = null
    @Volatile private var connectedState: ConnState.Connected? = null
    private var lastWaitingDetail: String? = null
    private var remoteError: String? = null
    private var videoW = 0
    private var videoH = 0
    private var immersive = false
    private var lastKeyframeRequest = 0L

    // Stats
    @Volatile private var receivedFrames = 0L
    @Volatile private var receivedBytes = 0L
    private var lastStatsAt = SystemClock.elapsedRealtime()
    private var lastReceivedFrames = 0L
    private var lastDecodedFrames = 0L
    private var lastReceivedBytes = 0L
    @Volatile private var fpsReceived = 0.0
    @Volatile private var fpsDecoded = 0.0
    @Volatile private var mbps = 0.0

    private val backgroundStop = Runnable { client.stop("tablet app in background") }
    private val fadeHandle = Runnable { controlHandle.animate().alpha(0.15f).setDuration(400).start() }
    private val hidePanel = Runnable { controlPanel.visibility = View.GONE }
    private val statsTick = object : Runnable {
        override fun run() { updateStats(); main.postDelayed(this, 500) }
    }

    // MARK: lifecycle

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        prefs = Prefs(this)
        bindViews()
        handleIntent(intent)
        panel = PanelInfo.read(this)
        caps = DecoderCaps.detect(panel.widthPx, panel.heightPx)
        Log.i(TAG, "panel $panel decoder $caps")

        decoder = VideoDecoder(this)
        decoder.start()
        client = SessionClient(this, ::clientInfo, { prefs.token }, { prefs.port })
        surfaceView.holder.addCallback(this)

        touch = TouchInputController(surfaceView,
            enabled = { prefs.touchInput && streamConfig?.inputEnabled == true },
            onPointer = { p -> client.sendPointer(Payloads.pointer(p.action, p.button, p.x, p.y, p.scrollX, p.scrollY)) },
            onInactiveTap = { showControls() })
        touch.attach()

        render(ConnState.Idle)
        if (prefs.autoConnect || intent?.action == ACTION_CONNECT) client.start()
        main.post(statsTick)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (handleIntent(intent) || !client.isRunning) client.reconnectNow()
    }

    /** Returns true when a new pairing token was stored. */
    private fun handleIntent(i: Intent?): Boolean {
        if (i?.action != ACTION_CONNECT) return false
        // The Mac only sends CONNECT on replug or when its user clicks Connect: an explicit request.
        prefs.autoConnect = true
        val token = i.getStringExtra("ep_token")?.lowercase()
        val port = i.getIntExtra("ep_port", 0)
        if (port in 1024..65535) prefs.port = port
        if (token != null && Auth.isValidToken(token) && token != prefs.token) {
            prefs.token = token
            Log.i(TAG, "paired with Mac over USB")
            return true
        }
        return false
    }

    override fun onStart() {
        super.onStart()
        main.removeCallbacks(backgroundStop)
        client.setPaused(false)
        if (!client.isRunning && prefs.autoConnect) client.start()
        if (immersive) Immersive.enter(this)
    }

    override fun onStop() {
        super.onStop()
        // Screen off / app hidden: tell the Mac to stop encoding; drop the session if it lasts.
        client.setPaused(true)
        main.postDelayed(backgroundStop, BACKGROUND_DISCONNECT_MS)
    }

    override fun onDestroy() {
        main.removeCallbacksAndMessages(null)
        client.shutdown()
        decoder.stop()
        super.onDestroy()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && immersive) Immersive.enter(this)
    }

    // MARK: views

    private fun bindViews() {
        videoContainer = findViewById(R.id.videoContainer)
        surfaceView = findViewById(R.id.surface)
        statusScreen = findViewById(R.id.statusScreen)
        statusTitle = findViewById(R.id.statusTitle)
        statusDetail = findViewById(R.id.statusDetail)
        transportState = findViewById(R.id.transportState)
        progress = findViewById(R.id.progress)
        statsOverlay = findViewById(R.id.statsOverlay)
        controlHandle = findViewById(R.id.controlHandle)
        controlPanel = findViewById(R.id.controlPanel)
        btnQuality = findViewById(R.id.btnQuality)
        btnScaling = findViewById(R.id.btnScaling)
        btnTouch = findViewById(R.id.btnTouch)
        btnStats = findViewById(R.id.btnStats)
        cursorView = findViewById(R.id.cursor)

        findViewById<Button>(R.id.btnConnect).setOnClickListener {
            prefs.autoConnect = true
            remoteError = null
            client.reconnectNow()
        }
        findViewById<Button>(R.id.btnDevOptions).setOnClickListener {
            try { startActivity(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)) }
            catch (e: Exception) { startActivity(Intent(Settings.ACTION_SETTINGS)) }
        }
        findViewById<Button>(R.id.btnSettings).setOnClickListener { showSettingsDialog() }
        controlHandle.setOnClickListener {
            showControls()
            controlPanel.visibility = if (controlPanel.visibility == View.VISIBLE) View.GONE else View.VISIBLE
            refreshPanel()
            main.removeCallbacks(hidePanel); main.postDelayed(hidePanel, 6000)
        }
        btnQuality.setOnClickListener {
            val cur = streamConfig?.quality ?: "balanced"
            val next = QUALITIES[(QUALITIES.indexOf(cur) + 1).mod(QUALITIES.size)]
            client.sendSettings(mapOf("quality" to next)); keepPanel()
        }
        btnScaling.setOnClickListener {
            val cur = streamConfig?.preset ?: "comfortable"
            val next = PRESETS[(PRESETS.indexOf(cur) + 1).mod(PRESETS.size)]
            client.sendSettings(mapOf("preset" to next)); keepPanel()
        }
        btnTouch.setOnClickListener { prefs.touchInput = !prefs.touchInput; refreshPanel(); keepPanel() }
        btnStats.setOnClickListener { prefs.showStats = !prefs.showStats; refreshPanel(); updateStats(); keepPanel() }
        findViewById<Button>(R.id.btnInfo).setOnClickListener { showInfoDialog() }
        findViewById<Button>(R.id.btnDisconnect).setOnClickListener {
            controlPanel.visibility = View.GONE
            prefs.autoConnect = false
            client.stop("disconnected on tablet")
        }
    }

    private fun keepPanel() { main.removeCallbacks(hidePanel); main.postDelayed(hidePanel, 6000) }

    private fun showControls() {
        if (connectedState == null) return
        controlHandle.visibility = View.VISIBLE
        controlHandle.animate().cancel()
        controlHandle.alpha = 0.6f
        main.removeCallbacks(fadeHandle)
        main.postDelayed(fadeHandle, 3000)
    }

    private fun refreshPanel() {
        val cfg = streamConfig
        btnQuality.text = getString(R.string.quality_fmt, qualityLabel(cfg?.quality ?: "balanced"))
        btnScaling.text = getString(R.string.scaling_fmt, presetLabel(cfg?.preset ?: "comfortable"))
        btnTouch.text = when {
            cfg != null && !cfg.inputEnabled -> getString(R.string.touch_mac_disabled)
            prefs.touchInput -> getString(R.string.touch_on)
            else -> getString(R.string.touch_off)
        }
        btnStats.text = getString(if (prefs.showStats) R.string.stats_on else R.string.stats_off)
    }

    private fun qualityLabel(q: String) = getString(when (q) { "performance" -> R.string.q_performance; "quality" -> R.string.q_quality; else -> R.string.q_balanced })
    private fun presetLabel(p: String) = getString(when (p) {
        "native" -> R.string.p_native; "large" -> R.string.p_large; "performance" -> R.string.p_performance
        "custom" -> R.string.p_custom; else -> R.string.p_comfortable })

    // MARK: state rendering (main thread)

    private fun render(state: ConnState) {
        val connected = state as? ConnState.Connected
        connectedState = connected
        if (connected != null) {
            streamConfig = connected.config ?: streamConfig
            statusScreen.visibility = View.GONE
            if (!immersive) { immersive = true; Immersive.enter(this) }
            showControls()
            refreshPanel()
            streamConfig?.let { cfg ->
                // Tablet pixels → Mac points for two-finger scrolling.
                if (cfg.width > 0 && videoContainer.width > 0) {
                    val contentW = AspectFitLayout.fit(videoContainer.width, videoContainer.height, cfg.width, cfg.height).first
                    touch.setScrollScale(cfg.logicalWidth.toFloat().coerceAtLeast(1f) / contentW.coerceAtLeast(1))
                }
            }
            // Layout may still be settling after a size change: place the cursor after the next pass.
            surfaceView.post { updateCursorView() }
            return
        }
        streamConfig = null
        cursorVisible = false
        cursorView.hide()
        controlHandle.visibility = View.GONE
        controlPanel.visibility = View.GONE
        statusScreen.visibility = View.VISIBLE
        if (immersive) { immersive = false; Immersive.exit(this) }
        when (state) {
            is ConnState.Idle -> {
                progress.visibility = View.GONE
                statusTitle.text = getString(R.string.disconnected)
                statusDetail.text = getString(R.string.disconnected_detail)
            }
            is ConnState.NotPaired -> {
                progress.visibility = View.GONE
                statusTitle.text = getString(R.string.not_paired)
                statusDetail.text = getString(R.string.not_paired_detail)
            }
            is ConnState.WaitingForMac -> {
                progress.visibility = View.VISIBLE
                lastWaitingDetail = state.detail
                statusTitle.text = getString(R.string.connecting)
                statusDetail.text = remoteError?.let { getString(R.string.mac_error, it) } ?: getString(R.string.connecting_detail)
            }
            is ConnState.Handshaking -> {
                progress.visibility = View.VISIBLE
                statusTitle.text = getString(R.string.starting_stream)
                statusDetail.text = getString(R.string.handshaking)
            }
            is ConnState.Rejected -> {
                progress.visibility = View.GONE
                statusTitle.text = getString(R.string.rejected)
                statusDetail.text = getString(R.string.rejected_detail, state.message)
            }
            is ConnState.Connected -> {}
        }
        transportState.text = transportText(state)
    }

    @Suppress("DEPRECATION")
    private fun transportText(state: ConnState): String {
        val battery = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val usb = battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) == BatteryManager.BATTERY_PLUGGED_USB
        val adb = try { Settings.Global.getInt(contentResolver, Settings.Global.ADB_ENABLED, 0) == 1 } catch (_: Exception) { false }
        val line1 = getString(R.string.usb_state, getString(if (usb) R.string.state_connected else R.string.state_not_detected),
            getString(if (adb) R.string.state_on else R.string.state_off))
        val tunnel = when {
            state is ConnState.WaitingForMac && state.detail == SessionClient.DETAIL_NO_TUNNEL -> getString(R.string.tunnel_none)
            state is ConnState.WaitingForMac && state.detail == SessionClient.DETAIL_NO_SERVER -> getString(R.string.tunnel_no_server)
            state is ConnState.Handshaking || state is ConnState.Rejected -> getString(R.string.tunnel_ok)
            state is ConnState.WaitingForMac -> getString(R.string.tunnel_unknown)
            else -> null
        }
        return if (tunnel != null) line1 + "\n" + getString(R.string.tunnel_state, tunnel) else line1
    }

    private fun updateStats() {
        val now = SystemClock.elapsedRealtime()
        val dt = (now - lastStatsAt).coerceAtLeast(1) / 1000.0
        if (dt >= 0.9) {
            val rf = receivedFrames; val df = decoder.decodedFrames; val rb = receivedBytes
            fpsReceived = (rf - lastReceivedFrames) / dt
            fpsDecoded = (df - lastDecodedFrames) / dt
            mbps = (rb - lastReceivedBytes) * 8 / dt / 1_000_000
            lastReceivedFrames = rf; lastDecodedFrames = df; lastReceivedBytes = rb; lastStatsAt = now
        }
        if (connectedState == null) {
            // Keep the transport hint fresh while waiting.
            if (statusScreen.visibility == View.VISIBLE) {
                val t = transportText(client.state)
                if (transportState.text.toString() != t) transportState.text = t
            }
            if (statsOverlay.visibility != View.GONE) statsOverlay.visibility = View.GONE
            return
        }
        if (!prefs.showStats) { if (statsOverlay.visibility != View.GONE) statsOverlay.visibility = View.GONE; return }
        if (statsOverlay.visibility != View.VISIBLE) statsOverlay.visibility = View.VISIBLE
        val cfg = streamConfig
        val text = String.format(
            "%dx%d · %.0f/%d fps · %.1f Mbps\ndecode %.1f ms · RTT %.1f ms · queue %d · skipped %d\n%s%s",
            videoW, videoH, fpsDecoded, cfg?.fps ?: 0, mbps, decoder.lastDecodeMs, client.rttMs, decoder.queueDepth,
            decoder.droppedFrames, decoder.codecName, if (decoder.lowLatencyActive) " · low-latency" else "")
        // Only touch the view when the text changed: a static screen then causes no redraws at all.
        if (statsOverlay.text.toString() != text) statsOverlay.text = text
    }

    // MARK: dialogs

    private fun showSettingsDialog() {
        val pad = (16 * resources.displayMetrics.density).toInt()
        val box = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(pad, pad, pad, 0) }
        fun check(label: Int, value: Boolean, onChange: (Boolean) -> Unit) = CheckBox(this).apply {
            text = getString(label); isChecked = value; setOnCheckedChangeListener { _, v -> onChange(v) }; box.addView(this)
        }
        check(R.string.opt_autoconnect, prefs.autoConnect) { prefs.autoConnect = it }
        check(R.string.opt_touch, prefs.touchInput) { prefs.touchInput = it }
        check(R.string.opt_stats, prefs.showStats) { prefs.showStats = it }
        box.addView(TextView(this).apply {
            text = getString(R.string.paired_with, getString(if (prefs.token != null) R.string.yes else R.string.no)) +
                "\n" + getString(R.string.about, BuildConfig.VERSION_NAME) +
                "\n${Build.MANUFACTURER} ${Build.MODEL} · Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})" +
                "\n${panel.widthPx}×${panel.heightPx} @ ${panel.refreshHz.toInt()} Hz · ${caps.name}${if (caps.hardware) " (HW)" else " (SW)"}"
            setPadding(0, pad, 0, 0)
        })
        AlertDialog.Builder(this, android.R.style.Theme_Material_Dialog_Alert)
            .setTitle(R.string.settings_title)
            .setView(box)
            .setNegativeButton(R.string.forget_pairing) { _, _ -> prefs.forgetPairing(); client.stop(); client.start() }
            .setPositiveButton(R.string.close, null)
            .show()
    }

    private fun showInfoDialog() {
        val c = connectedState
        val cfg = streamConfig
        val msg = buildString {
            append("Mac: ${c?.serverName ?: "—"}\n")
            append("Mode: ${cfg?.mode ?: "—"}\n")
            if (cfg != null) {
                append("Mac display: ${cfg.logicalWidth}×${cfg.logicalHeight}${if (cfg.hiDPI) " (HiDPI)" else ""}\n")
                append("Stream: ${cfg.width}×${cfg.height} @ ${cfg.fps} fps, ${cfg.bitrate / 1000} kbps target\n")
            }
            append("Received: %.1f fps, %.1f Mbps\n".format(fpsReceived, mbps))
            append("Decoder: ${decoder.codecName}${if (decoder.lowLatencyActive) " (low-latency)" else ""}\n")
            append("Transport: USB · adb reverse 127.0.0.1:${prefs.port} · RTT %.1f ms".format(client.rttMs))
        }
        AlertDialog.Builder(this, android.R.style.Theme_Material_Dialog_Alert)
            .setTitle(R.string.connection_info).setMessage(msg).setPositiveButton(R.string.close, null).show()
    }

    // MARK: SessionListener

    private fun clientInfo(): ClientInfo {
        val harmony = try {
            @Suppress("PrivateApi")
            val c = Class.forName("android.os.SystemProperties")
            c.getMethod("get", String::class.java).invoke(null, "hw_sc.build.platform.version") as? String ?: ""
        } catch (_: Exception) { "" }
        val device = linkedMapOf<String, Any?>(
            "manufacturer" to Build.MANUFACTURER, "model" to Build.MODEL, "sdk" to Build.VERSION.SDK_INT,
            "release" to Build.VERSION.RELEASE, "harmony" to harmony, "abi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: ""),
        )
        return ClientInfo(device, panel.toMap(), caps.toMap(), BuildConfig.VERSION_NAME)
    }

    override fun onState(state: ConnState) {
        if (state is ConnState.Connected) remoteError = null
        main.post { render(state) }
    }

    override fun onVideoConfig(cfg: Payloads.VideoConfig) = decoder.onConfig(cfg)

    override fun onVideoFrame(frame: Payloads.VideoFrame, receivedNanos: Long) {
        receivedFrames++
        receivedBytes += frame.length
        decoder.onFrame(frame, receivedNanos)
    }

    override fun onRemoteError(code: String, message: String) {
        Log.w(TAG, "Mac error $code: $message")
        remoteError = message
        main.post { statusDetail.text = getString(R.string.mac_error, message) }
    }

    override fun onCursorPos(pos: Payloads.CursorPos) {
        cursorX = pos.x; cursorY = pos.y; cursorVisible = pos.visible
        if (cursorPosted.compareAndSet(false, true)) main.post(applyCursor)
    }

    override fun onCursorImage(img: Payloads.CursorImage) {
        val bmp = BitmapFactory.decodeByteArray(img.png, 0, img.png.size) ?: return
        main.post {
            cursorBitmap = bmp
            cursorImage = img
            updateCursorView()
        }
    }

    /** Places the cursor over the video's letterboxed content area. Main thread. */
    private fun updateCursorView() {
        val cfg = streamConfig
        val img = cursorImage
        val bmp = cursorBitmap
        if (cfg == null || !cfg.localCursor || !cursorVisible || img == null || bmp == null || connectedState == null ||
            surfaceView.width == 0 || cfg.logicalWidth <= 0) {
            cursorView.hide()
            return
        }
        val scale = surfaceView.width.toFloat() / cfg.logicalWidth          // macOS points → tablet px
        val left = videoContainer.left + surfaceView.left
        val top = videoContainer.top + surfaceView.top
        cursorView.show(bmp,
            left + cursorX / 65535f * surfaceView.width - img.hotX * scale,
            top + cursorY / 65535f * surfaceView.height - img.hotY * scale,
            img.widthPt * scale, img.heightPt * scale)
    }

    override fun statsSnapshot(): Map<String, Any?> = linkedMapOf(
        "receivedFps" to fpsReceived, "decodedFps" to fpsDecoded, "decodeMs" to decoder.lastDecodeMs,
        "droppedFrames" to decoder.droppedFrames, "queue" to decoder.queueDepth, "mbps" to mbps,
    )

    // MARK: VideoDecoder.Callbacks

    override fun requestKeyframe(reason: String) {
        val now = SystemClock.elapsedRealtime()
        if (now - lastKeyframeRequest < 250) return
        lastKeyframeRequest = now
        Log.i(TAG, "keyframe request: $reason")
        client.requestKeyframe()
    }

    override fun onFrameRendered(frameId: Int, receiveToRenderMicros: Int) = client.sendFrameAck(frameId, receiveToRenderMicros)

    override fun onDecoderInfo(name: String, lowLatency: Boolean) { Log.i(TAG, "decoder $name lowLatency=$lowLatency") }

    override fun onVideoSize(width: Int, height: Int) {
        main.post {
            videoW = width; videoH = height
            videoContainer.setVideoSize(width, height)
            streamConfig?.let { render(ConnState.Connected(it, connectedState?.serverName ?: "Mac")) }
        }
    }

    // MARK: SurfaceHolder.Callback

    override fun surfaceCreated(holder: SurfaceHolder) = decoder.setSurface(holder.surface)
    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = decoder.setSurface(holder.surface)
    override fun surfaceDestroyed(holder: SurfaceHolder) = decoder.setSurface(null)
}
