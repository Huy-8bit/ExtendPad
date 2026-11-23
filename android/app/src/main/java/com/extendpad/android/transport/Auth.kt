package com.extendpad.android.transport

import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** HMAC-SHA256 challenge/response, identical to the Mac side (see PROTOCOL.md §3). */
object Auth {
    private val random = SecureRandom()

    fun randomHex(bytes: Int): String {
        val b = ByteArray(bytes)
        random.nextBytes(b)
        return toHex(b)
    }

    fun toHex(b: ByteArray): String {
        val sb = StringBuilder(b.size * 2)
        for (x in b) sb.append(String.format("%02x", x.toInt() and 0xff))
        return sb.toString()
    }

    fun hexDecode(s: String): ByteArray? {
        if (s.length % 2 != 0) return null
        val out = ByteArray(s.length / 2)
        for (i in out.indices) {
            val hi = Character.digit(s[2 * i], 16)
            val lo = Character.digit(s[2 * i + 1], 16)
            if (hi < 0 || lo < 0) return null
            out[i] = ((hi shl 4) or lo).toByte()
        }
        return out
    }

    fun isValidToken(token: String?): Boolean = token != null && token.length == 64 && hexDecode(token) != null

    fun hmacHex(tokenHex: String, role: String, channel: String, clientNonce: String, serverNonce: String): String? {
        val key = hexDecode(tokenHex) ?: return null
        if (key.size != 32) return null
        val msg = "EXTENDPAD-v1|$role|$channel|${clientNonce.lowercase()}|${serverNonce.lowercase()}"
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return toHex(mac.doFinal(msg.toByteArray(Charsets.UTF_8)))
    }

    fun constantTimeEquals(a: String, b: String): Boolean =
        MessageDigest.isEqual(a.toByteArray(Charsets.US_ASCII), b.toByteArray(Charsets.US_ASCII))
}
