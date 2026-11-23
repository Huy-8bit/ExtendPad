package com.extendpad.android.settings

import android.content.Context
import com.extendpad.android.transport.Auth
import com.extendpad.android.transport.Wire

/** App-private preferences. The pairing token is only ever written from the ADB-delivered intent. */
class Prefs(context: Context) {
    private val sp = context.getSharedPreferences("extendpad", Context.MODE_PRIVATE)

    var token: String?
        get() = sp.getString("token", null)?.takeIf { Auth.isValidToken(it) }
        set(v) { sp.edit().putString("token", v).apply() }

    var port: Int
        get() = sp.getInt("port", Wire.DEFAULT_PORT).takeIf { it in 1024..65535 } ?: Wire.DEFAULT_PORT
        set(v) { sp.edit().putInt("port", v).apply() }

    var showStats: Boolean
        get() = sp.getBoolean("showStats", false)
        set(v) { sp.edit().putBoolean("showStats", v).apply() }

    var touchInput: Boolean
        get() = sp.getBoolean("touchInput", true)
        set(v) { sp.edit().putBoolean("touchInput", v).apply() }

    var autoConnect: Boolean
        get() = sp.getBoolean("autoConnect", true)
        set(v) { sp.edit().putBoolean("autoConnect", v).apply() }

    fun forgetPairing() { sp.edit().remove("token").apply() }
}
