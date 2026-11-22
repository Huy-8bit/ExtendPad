package com.extendpad.android

import com.extendpad.android.display.AspectFitLayout
import com.extendpad.android.input.GestureEngine
import com.extendpad.android.transport.AnnexB
import com.extendpad.android.transport.Auth
import com.extendpad.android.transport.FrameIO
import com.extendpad.android.transport.MiniJson
import com.extendpad.android.transport.Payloads
import com.extendpad.android.transport.ProtocolException
import com.extendpad.android.transport.Wire
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.io.File
import java.io.InputStream

/** Reads ../../shared/protocol/test-vectors.json — the same file the Mac tests use. */
private fun vectors(): Map<String, Any?> {
    var dir = File("").absoluteFile
    repeat(5) {
        val f = File(dir, "shared/protocol/test-vectors.json")
        if (f.exists()) return MiniJson.parseObject(f.readText())
        dir = dir.parentFile ?: return@repeat
    }
    throw IllegalStateException("test-vectors.json not found from ${File("").absolutePath}")
}

private fun hex(b: ByteArray) = Auth.toHex(b)

/** Delivers one byte per read() call to exercise partial reads. */
private class TrickleStream(private val data: ByteArray) : InputStream() {
    private var i = 0
    override fun read(): Int = if (i < data.size) data[i++].toInt() and 0xff else -1
    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (i >= data.size) return -1
        if (len == 0) return 0
        b[off] = data[i++]; return 1
    }
}

class AuthTest {
    @Test fun sharedHmacVectors() {
        val v = vectors()
        val token = v["token"] as String
        @Suppress("UNCHECKED_CAST")
        val cases = v["auth"] as List<Map<String, String>>
        assertEquals(2, cases.size)
        for (c in cases) {
            assertEquals(c["clientMac"], Auth.hmacHex(token, "client", c["channel"]!!, c["clientNonce"]!!, c["serverNonce"]!!))
            assertEquals(c["serverProof"], Auth.hmacHex(token, "server", c["channel"]!!, c["clientNonce"]!!, c["serverNonce"]!!))
        }
    }

    @Test fun tokenValidation() {
        assertTrue(Auth.isValidToken("a".repeat(64)))
        assertFalse(Auth.isValidToken("a".repeat(63)))
        assertFalse(Auth.isValidToken("z".repeat(64)))
        assertFalse(Auth.isValidToken(null))
        assertNull(Auth.hmacHex("abcd", "client", "control", "00", "00"))
    }

    @Test fun constantTimeEquals() {
        assertTrue(Auth.constantTimeEquals("abc", "abc"))
        assertFalse(Auth.constantTimeEquals("abc", "abd"))
        assertFalse(Auth.constantTimeEquals("abc", "ab"))
    }

    @Test fun randomHex() {
        val a = Auth.randomHex(16)
        assertEquals(32, a.length)
        assertFalse(a == Auth.randomHex(16))
    }
}

class FramingTest {
    @Test fun sharedFrameVectors() {
        @Suppress("UNCHECKED_CAST")
        val frames = vectors()["frames"] as Map<String, String>
        assertEquals(frames["ping_id1_t2"], hex(FrameIO.encode(Wire.PING, Payloads.ping(1, 2))))
        assertEquals(frames["input_down_left_32768_65535_m5_120"],
            hex(FrameIO.encode(Wire.INPUT_POINTER, Payloads.pointer(1, 0, 32768, 65535, -5, 120))))
        // Cursor messages are produced by the Mac: parse the shared bytes.
        val pos = Auth.hexDecode(frames["cursor_pos_x1000_y65535_visible"]!!)!!
        val cp = Payloads.parseCursorPos(pos.copyOfRange(5, pos.size))!!
        assertEquals(1000, cp.x); assertEquals(65535, cp.y); assertTrue(cp.visible)
        val img = Auth.hexDecode(frames["cursor_image_17x23_hot4x5_png_89504e47"]!!)!!
        val ci = Payloads.parseCursorImage(img.copyOfRange(5, img.size))!!
        assertEquals(17, ci.widthPt); assertEquals(23, ci.heightPt); assertEquals(4, ci.hotX); assertEquals(5, ci.hotY)
        assertEquals(4, ci.png.size)
        assertNull(Payloads.parseCursorImage(byteArrayOf(0, 0, 0, 0, 0, 0, 0, 0, 1)))  // 0x0 rejected
    }

    @Test fun partialReadsByteByByte() {
        val big = ByteArray(100_000) { (it % 251).toByte() }
        val stream = FrameIO.encode(Wire.HELLO, "{}".toByteArray()) + FrameIO.encode(Wire.KEYFRAME_REQUEST) + FrameIO.encode(Wire.VIDEO_FRAME, big)
        val input = DataInputStream(TrickleStream(stream))
        val a = FrameIO.read(input, Wire.MAX_VIDEO)
        assertEquals(Wire.HELLO, a.type); assertEquals("{}", String(a.payload))
        val b = FrameIO.read(input, Wire.MAX_VIDEO)
        assertEquals(Wire.KEYFRAME_REQUEST, b.type); assertEquals(0, b.payload.size)
        val c = FrameIO.read(input, Wire.MAX_VIDEO)
        assertArrayEquals(big, c.payload)
    }

    @Test fun rejectsOversizedAndZeroLength() {
        val oversized = byteArrayOf(0, 1, 0, 1, 0x31)
        try { FrameIO.read(DataInputStream(ByteArrayInputStream(oversized)), 65_536); fail() } catch (e: ProtocolException) {}
        try { FrameIO.read(DataInputStream(ByteArrayInputStream(byteArrayOf(0, 0, 0, 0, 1))), 65_536); fail() } catch (e: ProtocolException) {}
    }

    @Test fun pointerClamping() {
        val p = Payloads.pointer(3, 0, 70_000, -5, 99_999, -99_999)
        assertEquals(12, p.size)
        assertEquals(0xff.toByte(), p[2]); assertEquals(0xff.toByte(), p[3])   // x clamped to 65535
        assertEquals(0, p[4].toInt()); assertEquals(0, p[5].toInt())             // y clamped to 0
    }

    @Test fun videoPayloadParsing() {
        val cfg = byteArrayOf(0x07, 0xD0.toByte(), 0x04, 0xB0.toByte(), 100, 50, 0, 0, 0, 0, 0, 1, 0x67, 0, 0, 0, 1, 0x68)
        val vc = Payloads.parseVideoConfig(cfg)!!
        assertEquals(2000, vc.width); assertEquals(1200, vc.height); assertEquals(100, vc.profileIdc)
        assertNull(Payloads.parseVideoConfig(byteArrayOf(0, 0, 0, 0, 0, 0, 0, 0, 0)))  // 0x0 rejected

        val frame = ByteArray(21 + 5)
        frame[3] = 7; frame[4] = 3
        System.arraycopy(byteArrayOf(0, 0, 0, 1, 0x65), 0, frame, 21, 5)
        val vf = Payloads.parseVideoFrame(frame)!!
        assertEquals(7, vf.frameId); assertTrue(vf.keyframe); assertTrue(vf.idleRefresh); assertEquals(5, vf.length)
        assertNull(Payloads.parseVideoFrame(ByteArray(21)))
    }

    @Test fun pingPong() {
        val p = Payloads.parsePing(Payloads.ping(42, 123456789))!!
        assertEquals(42, p.id); assertEquals(123456789, p.micros)
        val q = Payloads.parsePong(Payloads.pong(1, 2, 3))!!
        assertEquals(3, q.responder)
        assertNull(Payloads.parsePong(ByteArray(3)))
    }
}

class JsonTest {
    @Test fun roundTrip() {
        val m = linkedMapOf<String, Any?>("a" to 1, "b" to "x\"y\n", "c" to listOf(true, null, 2.5), "d" to mapOf("e" to -3))
        val s = MiniJson.stringify(m)
        val back = MiniJson.parseObject(s)
        assertEquals(1L, back["a"]); assertEquals("x\"y\n", back["b"])
        assertEquals(listOf(true, null, 2.5), back["c"])
        assertEquals(-3L, (back["d"] as Map<*, *>)["e"])
    }

    @Test fun parsesMacStyleJson() {
        val j = MiniJson.parseObject("""{"bitrate":14400000,"fps":60,"hiDPI":true,"mode":"extend","quality":"balanced","x":1.5e3,"u":"é"}""")
        assertEquals(14400000L, j["bitrate"]); assertEquals(true, j["hiDPI"]); assertEquals(1500.0, j["x"]); assertEquals("é", j["u"])
    }

    @Test fun rejectsGarbage() {
        for (bad in listOf("{", "{\"a\":}", "[1,2", "{\"a\":1} x", "nul", "\"abc")) {
            try { MiniJson.parse(bad); fail("accepted $bad") } catch (e: MiniJson.ParseException) {}
        }
        val deep = "[".repeat(100) + "]".repeat(100)
        try { MiniJson.parse(deep); fail() } catch (e: MiniJson.ParseException) {}
    }
}

class AnnexBTest {
    @Test fun splitAndTypes() {
        val csd = byteArrayOf(0, 0, 0, 1, 0x67, 0x64, 0, 0x2a, 0, 0, 0, 1, 0x68, 0xee.toByte(), 0x3c)
        val (sps, pps) = AnnexB.splitParameterSets(csd)!!
        assertArrayEquals(byteArrayOf(0, 0, 0, 1, 0x67, 0x64, 0, 0x2a), sps)
        assertArrayEquals(byteArrayOf(0, 0, 0, 1, 0x68, 0xee.toByte(), 0x3c), pps)
        assertEquals(listOf(7, 8), AnnexB.nalTypes(csd))
        assertNull(AnnexB.splitParameterSets(byteArrayOf(0, 0, 0, 1, 0x67, 1)))
    }
}

class GestureTest {
    private val out = ArrayList<GestureEngine.PointerOut>()
    private val g = GestureEngine({ out.add(it) }, slopPx = 10f, longPressMs = 500).apply { setViewSize(1001, 601) }

    private fun actions() = out.map { "${it.action}/${it.button}" }

    @Test fun tapIsLeftClick() {
        g.down(500f, 300f, 0); g.move(503f, 302f, 50); g.up(503f, 302f, 100)
        assertEquals(listOf("0/0", "1/0", "2/0"), actions())
        assertEquals(32767, out[1].x); assertEquals(32767, out[1].y)
    }

    @Test fun dragHoldsLeftButton() {
        g.down(100f, 100f, 0); g.move(150f, 100f, 50); g.move(200f, 120f, 80); g.up(200f, 120f, 120)
        assertEquals(listOf("0/0", "1/0", "0/0", "0/0", "2/0"), actions())
        assertEquals(GestureEngine.normalize(100f, 1001), out[1].x) // button pressed where the finger landed
    }

    @Test fun longPressIsRightClick() {
        g.down(100f, 100f, 0); g.checkLongPress(300); g.checkLongPress(600); g.up(100f, 100f, 900)
        assertEquals(listOf("0/0", "1/1", "2/1"), actions())
    }

    @Test fun twoFingerScrollAccumulates() {
        g.scrollScale = 0.5f
        g.down(100f, 100f, 0)
        g.secondPointerDown(150f, 100f)
        g.scrollMove(150f, 101f) // 0.5 px → nothing yet
        g.scrollMove(150f, 104f) // total 2 px
        g.cancel()
        val scrolls = out.filter { it.action == GestureEngine.SCROLL }
        assertEquals(1, scrolls.size); assertEquals(2, scrolls[0].scrollY); assertEquals(0, scrolls[0].scrollX)
    }

    @Test fun secondFingerDuringDragReleasesButton() {
        g.down(100f, 100f, 0); g.move(150f, 100f, 50); g.secondPointerDown(150f, 150f)
        assertEquals("2/0", actions().last())
    }

    @Test fun normalizeBounds() {
        assertEquals(0, GestureEngine.normalize(-10f, 100))
        assertEquals(65535, GestureEngine.normalize(99f, 100))
        assertEquals(65535, GestureEngine.normalize(5000f, 100))
    }
}

class AspectFitTest {
    @Test fun letterboxesInsteadOfStretching() {
        assertEquals(Pair(2000, 1200), AspectFitLayout.fit(2000, 1200, 2000, 1200))
        assertEquals(Pair(2000, 1200), AspectFitLayout.fit(2000, 1200, 1000, 600)) // upscales, same aspect
        val (w, h) = AspectFitLayout.fit(2000, 1200, 1920, 1200) // 16:10 stream on 5:3 panel
        assertEquals(1200, h); assertEquals(1920, w)
        val (w2, h2) = AspectFitLayout.fit(1200, 2000, 2000, 1200) // portrait container
        assertEquals(1200, w2); assertEquals(720, h2)
        assertNotNull(AspectFitLayout.fit(0, 0, 10, 10))
    }
}
