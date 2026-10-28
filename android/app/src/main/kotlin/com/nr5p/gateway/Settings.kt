package com.nr5p.gateway

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import com.nr5p.winlink.CMSTelnet
import com.nr5p.winlink.VARAMode
import com.nr5p.winlink.rig.RigHelmRig
import java.security.KeyStore
import java.util.Locale
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlin.properties.ReadWriteProperty
import kotlin.reflect.KProperty

enum class TransportKind(val raw: String) {
    /** Call an RMS gateway. */
    VARA("VARA"),
    /** Call another station directly (peer to peer) and swap messages. */
    P2P("P2P"),
    /** Wait for P2P calls and swap messages. */
    LISTEN("Listen"),
    /** Keyboard to keyboard: a BBS, node or chat with another operator. */
    TERMINAL("Terminal"),
    TELNET("Telnet");

    val usesRadio: Boolean get() = this != TELNET
}

enum class RigControlMode(val raw: String, val label: String) {
    OFF("off", "Off"),
    AUTO("auto", "Automatic"),
    RIGHELM("righelm", "RigHelm"),
    RIGCTLD("rigctld", "rigctld (hamlib)"),
}

/** Station and modem settings, kept in SharedPreferences and observable from Compose; the
 *  Winlink password, RigHelm password and API key are encrypted with an Android Keystore key. */
class Settings(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
    private val secrets = Secrets(context.getSharedPreferences("secrets", Context.MODE_PRIVATE))

    var callsign by string("callsign", "")
    var locator by string("locator", "")
    var transport by string("transport", TransportKind.VARA.raw)
    var gateway by string("gateway", "")
    /** The station to call for P2P or a terminal session. */
    var peer by string("peer", "")
    /** Terminal: wait for a call instead of calling. */
    var terminalAnswer by bool("terminalAnswer", false)
    var varaMode by string("varaMode", VARAMode.HF.raw)
    var bandwidth by string("bandwidth", "2300")
    var modemHost by string("modemHost", "127.0.0.1")
    var modemPort by int("modemPort", 8300)
    var cmsHost by string("cmsHost", CMSTelnet.HOST)
    var cmsPort by int("cmsPort", CMSTelnet.PORT)
    private var recentGatewaysRaw by string("recentGateways", "")
    /** The dial frequency to call on, as typed (kHz or MHz). */
    var dialFrequency by string("dialFrequency", "")
    /** "CALL=hz" pairs: the frequency last used for each gateway. */
    private var gatewayFrequenciesRaw by string("gatewayFrequencies", "")
    var rigControl by string("rigControl", RigControlMode.AUTO.raw)
    var rigHost by string("rigHost", "127.0.0.1")
    var rigPort by int("rigPort", RigHelmRig.DEFAULT_PORT)
    var rigLastEndpoint by string("rigLastEndpoint", "")
    /** Key the transmitter over CAT when the modem says PTT ON (off if the modem keys it itself). */
    var rigKeysPTT by bool("rigKeysPTT", true)
    var rigSetDataMode by bool("rigSetDataMode", true)
    /** Download the gateway list once a day when an API key is set. */
    var gatewayAutoUpdate by bool("gatewayAutoUpdate", true)
    var showModemTraffic by bool("showModemTraffic", true)

    val mycall: String get() = callsign.trim().uppercase()

    var transportKind: TransportKind
        get() = TransportKind.entries.firstOrNull { it.raw == transport } ?: TransportKind.VARA
        set(v) { transport = v.raw }

    var mode: VARAMode
        get() = VARAMode.entries.firstOrNull { it.raw == varaMode } ?: VARAMode.HF
        set(v) { varaMode = v.raw }

    var rigMode: RigControlMode
        get() = RigControlMode.entries.firstOrNull { it.raw == rigControl } ?: RigControlMode.AUTO
        set(v) { rigControl = v.raw }

    val recentGateways: List<String> get() = recentGatewaysRaw.split(",").filter { it.isNotEmpty() }

    fun remember(gateway: String) {
        recentGatewaysRaw = (listOf(gateway) + recentGateways.filter { it != gateway }).take(8).joinToString(",")
    }

    fun frequency(gateway: String): Long? {
        for (pair in gatewayFrequenciesRaw.split(",")) {
            val kv = pair.split("=")
            if (kv.size == 2 && kv[0] == gateway) return kv[1].toLongOrNull()
        }
        return null
    }

    fun remember(frequency: Long, gateway: String) {
        val pairs = gatewayFrequenciesRaw.split(",").filter { it.isNotEmpty() && !it.startsWith("$gateway=") }
        gatewayFrequenciesRaw = (listOf("$gateway=$frequency") + pairs).take(40).joinToString(",")
    }

    /** Picks a gateway, with the frequency last used for it. */
    fun select(gateway: String, frequency: Long? = null) {
        this.gateway = gateway
        (frequency ?: frequency(gateway))?.let { dialFrequency = String.format(Locale.US, "%.1f", it / 1000.0) }
    }

    /** Key for api.winlink.org (issued per program by the Winlink Development Team). */
    var winlinkAPIKey by secret("api")
    /** RigHelm station password (only needed to transmit). */
    var rigPassword by secret("rig")

    /** The Winlink password for the current call sign. */
    var password: String
        get() {
            passwordVersion.value
            return secrets.read("winlink:$mycall")
        }
        set(v) {
            secrets.write("winlink:$mycall", v)
            passwordVersion.value += 1
        }
    private val passwordVersion = mutableStateOf(0)

    // Observable preferences

    private fun <T> pref(key: String, read: SharedPreferences.() -> T, write: SharedPreferences.Editor.(T) -> Unit) =
        object : ReadWriteProperty<Any?, T> {
            val state: MutableState<T> = mutableStateOf(prefs.read())
            override fun getValue(thisRef: Any?, property: KProperty<*>) = state.value
            override fun setValue(thisRef: Any?, property: KProperty<*>, value: T) {
                state.value = value
                prefs.edit().apply { write(value) }.apply()
            }
        }

    private fun string(key: String, def: String) = pref(key, { getString(key, def) ?: def }, { putString(key, it) })
    private fun int(key: String, def: Int) = pref(key, { getInt(key, def) }, { putInt(key, it) })
    private fun bool(key: String, def: Boolean) = pref(key, { getBoolean(key, def) }, { putBoolean(key, it) })

    private fun secret(name: String) = object : ReadWriteProperty<Any?, String> {
        val state = mutableStateOf(secrets.read(name))
        override fun getValue(thisRef: Any?, property: KProperty<*>) = state.value
        override fun setValue(thisRef: Any?, property: KProperty<*>, value: String) {
            state.value = value
            secrets.write(name, value)
        }
    }
}

/** Small secrets, AES-GCM encrypted with a key that never leaves the Android Keystore
 *  (the counterpart of the iOS Keychain items: this device only, not backed up). */
private class Secrets(private val prefs: SharedPreferences) {
    private val alias = "gateway-secrets"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(alias, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        return gen.generateKey()
    }

    fun read(name: String): String {
        val stored = prefs.getString(name, null) ?: return ""
        return try {
            val raw = Base64.decode(stored, Base64.NO_WRAP)
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, raw, 0, 12))
            String(c.doFinal(raw, 12, raw.size - 12), Charsets.UTF_8)
        } catch (_: Exception) {
            ""
        }
    }

    fun write(name: String, value: String) {
        if (value.isEmpty()) {
            prefs.edit().remove(name).apply()
            return
        }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        val out = c.iv + c.doFinal(value.toByteArray(Charsets.UTF_8))
        prefs.edit().putString(name, Base64.encodeToString(out, Base64.NO_WRAP)).apply()
    }
}
