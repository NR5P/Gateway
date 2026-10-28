package com.nr5p.gateway

import android.content.Context
import android.net.wifi.WifiManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.nr5p.winlink.rig.DialFrequency
import com.nr5p.winlink.rig.Rig
import com.nr5p.winlink.rig.RigDiscovery
import com.nr5p.winlink.rig.RigEndpoint
import com.nr5p.winlink.rig.RigHelmRig
import com.nr5p.winlink.rig.RigMode
import com.nr5p.winlink.rig.RigStatus
import com.nr5p.winlink.rig.RigctldRig
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

class RigControlException(message: String) : Exception(message)

/** The radio: finds it (RigHelm on the LAN or this phone, or a rigctld), keeps a CAT session
 *  open while it is in use, sets frequency and mode before a call, and keys the transmitter
 *  when the modem says PTT ON.
 *
 *  Transmit safety: keying only follows the modem's PTT (or the Tune button), always in the
 *  order the modem sent it; a PTT held longer than [MAX_KEYED_MS] is dropped; the radio is
 *  un-keyed when a session ends or the rig is disconnected. */
class RigController(private val context: Context, private val settings: Settings) {
    var endpoints by mutableStateOf<List<RigEndpoint>>(emptyList()); private set
    var scanning by mutableStateOf(false); private set
    var connected by mutableStateOf<String?>(null); private set
    var status by mutableStateOf(RigStatus()); private set
    var message by mutableStateOf("")

    companion object {
        /** Longest the modem may hold PTT before this lets go (VARA frames are a few seconds). */
        const val MAX_KEYED_MS = 45_000L
    }

    var log: (LogLine.Kind, String) -> Unit = { _, _ -> }

    private val main = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var rig: Rig? = null
    private var connecting: CompletableDeferred<Rig>? = null
    private var poller: Job? = null
    private var watchdog: Job? = null
    private var pttQueue: Channel<Boolean>? = null
    private var pttWorker: Job? = null

    suspend fun scan() {
        if (scanning) return
        scanning = true
        val modemHost = settings.modemHost.trim()
        // Android drops incoming broadcasts (RigHelm's answers to a broadcast probe) without this.
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        val lock = wifi?.createMulticastLock("gateway-rig-discovery")?.apply { setReferenceCounted(false); acquire() }
        try {
            endpoints = RigDiscovery.scan(hosts = if (modemHost == "127.0.0.1") emptyList() else listOf(modemHost))
        } finally {
            lock?.release()
            scanning = false
        }
        message = if (endpoints.isEmpty()) "No radio found. Start RigHelm (or rigctld) on the computer the radio is plugged into." else ""
    }

    /** The open rig, connecting (and on Automatic, searching) first if need be. */
    suspend fun open(): Rig {
        rig?.let { return it }
        connecting?.let { return it.await() }
        val d = CompletableDeferred<Rig>()
        connecting = d
        try {
            val r = connect()
            rig = r
            connected = r.name
            message = ""
            log(LogLine.Kind.INFO, "Radio: connected to ${r.name}")
            startPolling(r)
            d.complete(r)
            return r
        } catch (e: Exception) {
            d.completeExceptionally(e)
            throw e
        } finally {
            connecting = null
        }
    }

    private suspend fun connect(): Rig {
        val password = settings.rigPassword
        return when (settings.rigMode) {
            RigControlMode.OFF -> throw RigControlException("radio control is off")
            RigControlMode.RIGHELM -> RigHelmRig.connect(settings.rigHost.trim(), settings.rigPort, password)
            RigControlMode.RIGCTLD -> RigctldRig.connect(settings.rigHost.trim(), settings.rigPort)
            RigControlMode.AUTO -> {
                if (endpoints.isEmpty()) scan()
                // The last radio used first, then RigHelm before rigctld, this device before the LAN.
                val ranked = endpoints.sortedBy { rank(it) }
                var last: Exception = RigControlException("no radio found (RigHelm or rigctld)")
                for (e in ranked) {
                    try {
                        val r: Rig = if (e.kind == RigEndpoint.Kind.RIGHELM) {
                            RigHelmRig.connect(e.host, e.port, password)
                        } else {
                            RigctldRig.connect(e.host, e.port)
                        }
                        settings.rigLastEndpoint = e.id
                        return r
                    } catch (err: Exception) {
                        log(LogLine.Kind.ERROR, "Radio: ${e.title}: ${err.message}")
                        last = err
                    }
                }
                throw last
            }
        }
    }

    private fun rank(e: RigEndpoint): Int =
        (if (e.id == settings.rigLastEndpoint) 0 else 10) +
            (if (e.kind == RigEndpoint.Kind.RIGHELM) 0 else 4) +
            (if (e.host == "127.0.0.1") 0 else 2) +
            (if (e.kind == RigEndpoint.Kind.RIGHELM && e.radio != "connected") 1 else 0)

    private fun startPolling(r: Rig) {
        poller?.cancel()
        poller = main.launch {
            while (isActive) {
                try {
                    status = r.status()
                } catch (e: Exception) {
                    lost(e)
                    return@launch
                }
                delay(1000)
            }
        }
    }

    private fun lost(e: Exception) {
        val r = rig ?: return
        log(LogLine.Kind.ERROR, "Radio: lost ${r.name}: ${e.message}")
        message = "Lost the radio: ${e.message}"
        disconnect()
    }

    fun disconnect() {
        poller?.cancel()
        watchdog?.cancel()
        pttQueue?.close()
        pttQueue = null
        pttWorker = null
        rig?.let { r -> CoroutineScope(Dispatchers.IO).launch { r.close() } }
        rig = null
        connected = null
        status = RigStatus()
    }

    /** Before a call: the gateway's dial frequency and the data mode. */
    suspend fun prepare(frequency: Long?, mode: RigMode) {
        val r = open()
        if (frequency != null) {
            r.setFrequency(frequency)
            log(LogLine.Kind.INFO, "Radio: ${DialFrequency.format(frequency)} MHz")
        }
        if (settings.rigSetDataMode) {
            r.setMode(mode)
            log(LogLine.Kind.INFO, "Radio: ${mode.raw}")
        }
        status = r.status()
    }

    /** Starts the antenna tuner. The radio transmits a carrier until it finishes. */
    suspend fun tune() {
        try {
            val r = open()
            r.tune()
            log(LogLine.Kind.INFO, "Radio: tuning")
            message = "Tuning…"
            delay(4000)
            if (message == "Tuning…") message = ""
        } catch (e: Exception) {
            message = "Tune failed: ${e.message}"
            log(LogLine.Kind.ERROR, "Radio: $message")
        }
    }

    /** Follows the modem's PTT, in order. Nothing is keyed unless the rig is already open. */
    fun followModem(on: Boolean) {
        val r = rig ?: return
        val queue = pttQueue ?: Channel<Boolean>(Channel.UNLIMITED).also { q ->
            pttQueue = q
            pttWorker = main.launch {
                for (key in q) {
                    try {
                        r.setPTT(key)
                    } catch (e: Exception) {
                        log(LogLine.Kind.ERROR, "Radio: PTT ${if (key) "on" else "off"} failed: ${e.message}")
                    }
                }
            }
        }
        queue.trySend(on)
        watchdog?.cancel()
        if (on) {
            val w = main.launch {
                delay(MAX_KEYED_MS)
                log(LogLine.Kind.ERROR, "Radio: PTT on for over ${MAX_KEYED_MS / 1000} s, un-keying")
                pttQueue?.trySend(false)
            }
            watchdog = w
            // A station that blocks transmit drops the command silently; say so.
            main.launch {
                delay(800)
                val s = runCatching { r.status() }.getOrNull() ?: return@launch
                if (w.isActive && !s.transmitting) {
                    log(LogLine.Kind.ERROR, "Radio: did not key. On RigHelm, set a password and allow remote transmit.")
                }
            }
        }
    }

    /** After a session: make sure the transmitter is off. */
    fun sessionEnded() {
        watchdog?.cancel()
        pttQueue?.trySend(false)
    }
}
