package com.extendpad.android.transport

import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** ExtendPad wire protocol v1 — see shared/protocol/PROTOCOL.md. */
object Wire {
    const val VERSION = 1
    const val MAGIC = "EXTENDPAD"
    const val DEFAULT_PORT = 27183
    const val MAX_CONTROL = 65_536
    const val MAX_VIDEO = 8 * 1024 * 1024

    const val HELLO = 0x01
    const val CHALLENGE = 0x02
    const val AUTH = 0x03
    const val ACCEPT = 0x04
    const val REJECT = 0x05
    const val STREAM_CONFIG = 0x10
    const val STATS = 0x11
    const val KEYFRAME_REQUEST = 0x12
    const val PING = 0x13
    const val PONG = 0x14
    const val FRAME_ACK = 0x15
    const val SETTINGS_REQUEST = 0x16
    const val ERROR = 0x17
    const val BYE = 0x18
    const val STREAM_PAUSE = 0x19
    const val STREAM_RESUME = 0x1A
    const val INPUT_POINTER = 0x20
    const val CURSOR_IMAGE = 0x21
    const val CURSOR_POS = 0x22
    const val VIDEO_CONFIG = 0x30
    const val VIDEO_FRAME = 0x31
}

class ProtocolException(msg: String) : IOException(msg)

class Frame(val type: Int, val payload: ByteArray) {
    fun json(): Map<String, Any?> = MiniJson.parseObject(String(payload, Charsets.UTF_8))
}

object FrameIO {
    fun encode(type: Int, payload: ByteArray = ByteArray(0)): ByteArray {
        val out = ByteArray(5 + payload.size)
        val n = 1 + payload.size
        out[0] = (n ushr 24).toByte(); out[1] = (n ushr 16).toByte(); out[2] = (n ushr 8).toByte(); out[3] = n.toByte()
        out[4] = type.toByte()
        System.arraycopy(payload, 0, out, 5, payload.size)
        return out
    }

    fun encodeJson(type: Int, obj: Map<String, Any?>): ByteArray =
        encode(type, MiniJson.stringify(obj).toByteArray(Charsets.UTF_8))

    /** Blocking read of one frame. `readFully` takes care of partial reads. */
    @Throws(IOException::class)
    fun read(input: DataInputStream, maxFrame: Int): Frame {
        val len = try { input.readInt() } catch (e: EOFException) { throw EOFException("peer closed") }
        if (len <= 0) throw ProtocolException("invalid frame length $len")
        if (len > maxFrame) throw ProtocolException("frame length $len exceeds $maxFrame")
        val type = input.readUnsignedByte()
        val payload = ByteArray(len - 1)
        input.readFully(payload)
        return Frame(type, payload)
    }

    fun write(out: OutputStream, bytes: ByteArray) {
        out.write(bytes)
        out.flush()
    }
}

/** Binary payload helpers (big-endian). */
object Payloads {
    fun ping(id: Long, micros: Long): ByteArray =
        ByteBuffer.allocate(16).order(ByteOrder.BIG_ENDIAN).putLong(id).putLong(micros).array()

    fun pong(id: Long, echoed: Long, responder: Long): ByteArray =
        ByteBuffer.allocate(24).order(ByteOrder.BIG_ENDIAN).putLong(id).putLong(echoed).putLong(responder).array()

    fun frameAck(frameId: Int, receiveToRenderMicros: Int): ByteArray =
        ByteBuffer.allocate(8).order(ByteOrder.BIG_ENDIAN).putInt(frameId).putInt(receiveToRenderMicros).array()

    /** INPUT_POINTER: u8 action, u8 button, u16 x, u16 y, i16 sx, i16 sy, u16 reserved. */
    fun pointer(action: Int, button: Int, x: Int, y: Int, scrollX: Int = 0, scrollY: Int = 0): ByteArray =
        ByteBuffer.allocate(12).order(ByteOrder.BIG_ENDIAN)
            .put(action.toByte()).put(button.toByte())
            .putShort(x.coerceIn(0, 65535).toShort()).putShort(y.coerceIn(0, 65535).toShort())
            .putShort(scrollX.coerceIn(-32768, 32767).toShort()).putShort(scrollY.coerceIn(-32768, 32767).toShort())
            .putShort(0).array()

    data class Ping(val id: Long, val micros: Long)
    fun parsePing(p: ByteArray): Ping? {
        if (p.size < 16) return null
        val b = ByteBuffer.wrap(p).order(ByteOrder.BIG_ENDIAN)
        return Ping(b.long, b.long)
    }

    data class Pong(val id: Long, val echoed: Long, val responder: Long)
    fun parsePong(p: ByteArray): Pong? {
        if (p.size < 24) return null
        val b = ByteBuffer.wrap(p).order(ByteOrder.BIG_ENDIAN)
        return Pong(b.long, b.long, b.long)
    }

    /** CURSOR_POS: u16 x, u16 y (0..65535 across the Mac display), u8 visible. */
    class CursorPos(val x: Int, val y: Int, val visible: Boolean)
    fun parseCursorPos(p: ByteArray): CursorPos? {
        if (p.size < 5) return null
        val b = ByteBuffer.wrap(p).order(ByteOrder.BIG_ENDIAN)
        return CursorPos(b.short.toInt() and 0xffff, b.short.toInt() and 0xffff, b.get().toInt() != 0)
    }

    /** CURSOR_IMAGE: u16 widthPt, u16 heightPt, u16 hotX, u16 hotY (macOS points), PNG bytes. */
    class CursorImage(val widthPt: Int, val heightPt: Int, val hotX: Int, val hotY: Int, val png: ByteArray)
    fun parseCursorImage(p: ByteArray): CursorImage? {
        if (p.size <= 8) return null
        val b = ByteBuffer.wrap(p).order(ByteOrder.BIG_ENDIAN)
        val w = b.short.toInt() and 0xffff; val h = b.short.toInt() and 0xffff
        val hx = b.short.toInt() and 0xffff; val hy = b.short.toInt() and 0xffff
        if (w !in 1..256 || h !in 1..256 || hx > w || hy > h) return null
        return CursorImage(w, h, hx, hy, p.copyOfRange(8, p.size))
    }

    class VideoConfig(val width: Int, val height: Int, val profileIdc: Int, val levelIdc: Int, val csd: ByteArray)
    fun parseVideoConfig(p: ByteArray): VideoConfig? {
        if (p.size < 9) return null
        val b = ByteBuffer.wrap(p).order(ByteOrder.BIG_ENDIAN)
        val w = b.short.toInt() and 0xffff
        val h = b.short.toInt() and 0xffff
        val prof = b.get().toInt() and 0xff
        val lvl = b.get().toInt() and 0xff
        b.short
        if (w !in 16..8192 || h !in 16..8192) return null
        return VideoConfig(w, h, prof, lvl, p.copyOfRange(8, p.size))
    }

    class VideoFrame(val frameId: Int, val keyframe: Boolean, val idleRefresh: Boolean,
                     val ptsMicros: Long, val captureMicros: Long, val data: ByteArray, val offset: Int, val length: Int)
    fun parseVideoFrame(p: ByteArray): VideoFrame? {
        if (p.size <= 21) return null
        val b = ByteBuffer.wrap(p).order(ByteOrder.BIG_ENDIAN)
        val id = b.int
        val flags = b.get().toInt() and 0xff
        val pts = b.long
        val cap = b.long
        return VideoFrame(id, flags and 1 != 0, flags and 2 != 0, pts, cap, p, 21, p.size - 21)
    }
}

/** Annex-B helpers. */
object AnnexB {
    /** NAL unit types present in an Annex-B buffer. */
    fun nalTypes(d: ByteArray, off: Int = 0, len: Int = d.size): List<Int> {
        val out = ArrayList<Int>()
        var i = off
        val end = off + len
        while (i + 3 < end) {
            if (d[i].toInt() == 0 && d[i + 1].toInt() == 0) {
                val three = d[i + 2].toInt() == 1
                val four = d[i + 2].toInt() == 0 && d[i + 3].toInt() == 1
                if (three || four) {
                    val start = if (three) i + 3 else i + 4
                    if (start < end) out.add(d[start].toInt() and 0x1f)
                    i = start
                    continue
                }
            }
            i++
        }
        return out
    }

    /** Splits Annex-B SPS+PPS into csd-0 (SPS) and csd-1 (PPS), each keeping its start code. */
    fun splitParameterSets(csd: ByteArray): Pair<ByteArray, ByteArray>? {
        val starts = ArrayList<Int>()
        var i = 0
        while (i + 3 < csd.size) {
            if (csd[i].toInt() == 0 && csd[i + 1].toInt() == 0 && csd[i + 2].toInt() == 0 && csd[i + 3].toInt() == 1) {
                starts.add(i); i += 4
            } else i++
        }
        var sps: ByteArray? = null
        var pps: ByteArray? = null
        for ((k, s) in starts.withIndex()) {
            val e = if (k + 1 < starts.size) starts[k + 1] else csd.size
            if (s + 4 >= e) continue
            when (csd[s + 4].toInt() and 0x1f) {
                7 -> if (sps == null) sps = csd.copyOfRange(s, e)
                8 -> if (pps == null) pps = csd.copyOfRange(s, e)
            }
        }
        return if (sps != null && pps != null) Pair(sps, pps) else null
    }
}
