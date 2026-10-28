package com.nr5p.winlink.rig

import com.nr5p.winlink.ByteStream
import com.nr5p.winlink.TCPStream
import com.nr5p.winlink.write
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.Locale
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlin.math.abs

/** A radio shared by a RigHelm station, over RigHelm's LAN `CAT` session (TCP 4533).
 *
 *  The server greets with a nonce; the client proves the password with
 *  HMAC-SHA256(password, "ftdx3000:<nonce>:CAT"). After `OK` the session carries FTDX3000 CAT
 *  whatever the radio is: RigHelm translates for its Yaesu, Icom, Kenwood and Elecraft
 *  models. The server closes a CAT session that is silent for 5 s and un-keys a client that
 *  goes away, so this polls once a second. A station without a password (or with remote
 *  transmit off) drops the commands that key the radio. */
class RigHelmRig private constructor(
    private val stream: ByteStream,
    private val inbox: Inbox,
    server: String,
    /** RigHelm's key for the radio model, e.g. "ftdx3000", "ic7300". */
    val model: String,
) : Rig {
    override val name = "RigHelm $server" + if (model.isEmpty()) "" else ": $model"
    private val lock = Any()
    private var state = RigStatus()
    @Volatile private var keyed = false
    @Volatile private var failure: Exception? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    companion object {
        const val DEFAULT_PORT = 4533
        internal const val GREETING = "FTDX3000-REMOTE"

        suspend fun connect(host: String, port: Int = DEFAULT_PORT, password: String): RigHelmRig {
            val s = TCPStream.connect(host, port, 4.0)
            try {
                return open(s, password)
            } catch (e: Exception) {
                s.close()
                throw e
            }
        }

        /** Logs in on an open connection and starts polling. */
        internal suspend fun open(stream: ByteStream, password: String): RigHelmRig {
            val inbox = Inbox(stream)
            val greet = inbox.line(5.0, "waiting for the RigHelm greeting").split(" ").filter { it.isNotEmpty() }
            if (greet.size < 3 || greet[0] != GREETING) {
                inbox.cancel()
                throw RigException.NotRigHelm(greet.joinToString(" "))
            }
            val server = greet.drop(3).joinToString(" ")
            stream.write("HELLO CAT ${proof(password, greet[2], "CAT")}\n")
            val reply = inbox.line(5.0, "waiting for RigHelm to accept the login")
            val words = reply.split(" ").filter { it.isNotEmpty() }
            when (words.firstOrNull()) {
                "OK" -> {
                    val rig = RigHelmRig(stream, inbox, server, words.getOrElse(4) { "" })
                    rig.startTasks()
                    try {
                        rig.waitFor(3.0, "the frequency") { it.frequency != null }
                    } catch (e: Exception) {
                        rig.scope.cancel()
                        throw e
                    }
                    return rig
                }
                "DENIED" -> {
                    inbox.cancel()
                    throw RigException.Denied(reply.removePrefix("DENIED "))
                }
                else -> {
                    inbox.cancel()
                    throw RigException.NotRigHelm(reply)
                }
            }
        }

        /** Hex HMAC-SHA256 of "ftdx3000:<nonce>:<mode>"; an open server ignores it. */
        internal fun proof(password: String, nonce: String, mode: String): String {
            if (password.isEmpty()) return "-"
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(password.toByteArray(), "HmacSHA256"))
            return mac.doFinal("ftdx3000:$nonce:$mode".toByteArray()).joinToString("") { "%02x".format(it) }
        }

        internal val MODES = mapOf(
            '1' to "LSB", '2' to "USB", '3' to "CW", '4' to "FM", '5' to "AM", '6' to "RTTY-L", '7' to "CW-R",
            '8' to "DATA-L", '9' to "RTTY-U", 'A' to "DATA-FM", 'B' to "FM-N", 'C' to "DATA-U", 'D' to "AM-N",
            'E' to "C4FM", 'F' to "DV", 'G' to "WFM", 'H' to "DATA-AM", 'I' to "PSK", 'J' to "DATA-FMN",
        )
    }

    private fun startTasks() {
        scope.launch {
            try {
                while (isActive) {
                    val f = inbox.take(';'.code, 8.0, "waiting for RigHelm")
                    apply(String(f, Charsets.UTF_8))
                }
            } catch (e: Exception) {
                failure = e
            }
        }
        scope.launch {
            while (isActive) {
                runCatching { stream.write("FA;MD0;TX;") }
                delay(1000)
            }
        }
    }

    internal fun apply(frame: String) {
        val f = frame.filter { it >= ' ' && it != ';' }.uppercase()
        synchronized(lock) {
            if (f.startsWith("FA") && f.drop(2).toLongOrNull() != null) {
                state = state.copy(frequency = f.drop(2).toLong())
            } else if (f.startsWith("MD0") && f.length == 4) {
                state = state.copy(mode = MODES[f.last()] ?: state.mode)
            } else if (f.startsWith("TX") && f.length == 3) {
                state = state.copy(transmitting = f.last() != '0')
            }
        }
    }

    private fun current(): RigStatus {
        failure?.let { throw it }
        return synchronized(lock) { state }
    }

    private suspend fun waitFor(timeout: Double, what: String, ok: (RigStatus) -> Boolean) {
        val deadline = System.currentTimeMillis() + (timeout * 1000).toLong()
        while (System.currentTimeMillis() < deadline) {
            if (ok(current())) return
            delay(50)
        }
        throw RigException.NotConfirmed(what)
    }

    override suspend fun status(): RigStatus = current()

    override suspend fun setFrequency(hz: Long) {
        stream.write(String.format(Locale.US, "FA%08d;FA;", hz))
        // Some radios tune in 10 Hz steps.
        waitFor(2.0, "the frequency ${DialFrequency.format(hz)}") { abs((it.frequency ?: 0) - hz) < 20 }
    }

    override suspend fun setMode(mode: RigMode) {
        stream.write(if (mode == RigMode.DATA_FM) "MD0A;MD0;" else "MD0C;MD0;")
        waitFor(2.0, "the mode ${mode.raw}") { it.mode == mode.raw }
    }

    override suspend fun setPTT(on: Boolean) {
        keyed = on
        stream.write(if (on) "TX1;TX;" else "TX0;TX;")
    }

    override suspend fun tune() = stream.write("AC002;")

    override suspend fun close() {
        val wasKeyed = keyed
        keyed = false
        scope.cancel()
        if (wasKeyed) {
            runCatching { stream.write("TX0;") }
            delay(100)
        }
        inbox.cancel()
        stream.close()
    }
}
