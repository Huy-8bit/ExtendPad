package com.extendpad.android.decoder

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.util.Log

/** What the tablet's H.264 decoder can do; sent to the Mac in HELLO so it picks a compatible stream. */
data class DecoderCaps(
    val name: String,
    val hardware: Boolean,
    val lowLatency: Boolean,
    val maxWidth: Int,
    val maxHeight: Int,
    val highProfile: Boolean,
    val maxFpsNative: Int,
    val maxLevel: String,
) {
    fun toMap(): Map<String, Any?> = linkedMapOf(
        "name" to name, "hardware" to hardware, "lowLatency" to lowLatency, "maxWidth" to maxWidth,
        "maxHeight" to maxHeight, "highProfile" to highProfile, "maxFpsNative" to maxFpsNative, "maxLevel" to maxLevel,
    )

    companion object {
        private const val TAG = "ExtendPad.Caps"
        private const val MIME = MediaFormat.MIMETYPE_VIDEO_AVC

        fun isSoftware(info: MediaCodecInfo): Boolean {
            if (Build.VERSION.SDK_INT >= 29) return info.isSoftwareOnly
            val n = info.name.lowercase()
            return n.startsWith("omx.google.") || n.startsWith("c2.android.") || n.contains(".sw.") || n.endsWith(".sw")
        }

        /** Hardware AVC decoders first, then software ones. */
        fun candidates(): List<MediaCodecInfo> {
            val all = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { info ->
                !info.isEncoder && info.supportedTypes.any { it.equals(MIME, ignoreCase = true) }
            }
            return all.sortedBy { if (isSoftware(it)) 1 else 0 }
        }

        fun detect(nativeW: Int, nativeH: Int): DecoderCaps {
            val info = candidates().firstOrNull()
                ?: return DecoderCaps("none", false, false, 1920, 1080, false, 30, "?")
            return try {
                val caps = info.getCapabilitiesForType(MIME)
                val vc = caps.videoCapabilities
                val maxW = vc.supportedWidths.upper
                val maxH = vc.supportedHeights.upper
                val high = caps.profileLevels.any { it.profile == MediaCodecInfo.CodecProfileLevel.AVCProfileHigh ||
                        it.profile == MediaCodecInfo.CodecProfileLevel.AVCProfileConstrainedHigh }
                val maxLevel = caps.profileLevels.maxOfOrNull { it.level } ?: 0
                val ll = Build.VERSION.SDK_INT >= 30 && caps.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)
                val w = maxOf(nativeW, nativeH); val h = minOf(nativeW, nativeH)
                val fps = try {
                    when {
                        vc.isSizeSupported(w, h) -> vc.getSupportedFrameRatesFor(w, h).upper.toInt()
                        vc.isSizeSupported(h, w) -> vc.getSupportedFrameRatesFor(h, w).upper.toInt()
                        else -> 30
                    }
                } catch (e: IllegalArgumentException) { 30 }
                DecoderCaps(info.name, !isSoftware(info), ll, maxW, maxH, high, fps.coerceIn(15, 240), levelName(maxLevel))
            } catch (e: Exception) {
                Log.w(TAG, "capability query failed for ${info.name}", e)
                DecoderCaps(info.name, !isSoftware(info), false, 1920, 1080, false, 30, "?")
            }
        }

        private fun levelName(level: Int): String = when {
            level >= MediaCodecInfo.CodecProfileLevel.AVCLevel52 -> "5.2"
            level >= MediaCodecInfo.CodecProfileLevel.AVCLevel51 -> "5.1"
            level >= MediaCodecInfo.CodecProfileLevel.AVCLevel5 -> "5.0"
            level >= MediaCodecInfo.CodecProfileLevel.AVCLevel42 -> "4.2"
            level >= MediaCodecInfo.CodecProfileLevel.AVCLevel41 -> "4.1"
            level >= MediaCodecInfo.CodecProfileLevel.AVCLevel4 -> "4.0"
            else -> "<4"
        }
    }
}
