package com.nr5p.winlink.rig

import com.nr5p.winlink.ByteStream
import com.nr5p.winlink.TCPStream
import com.nr5p.winlink.write
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Hamlib's NET rigctl protocol (rigctld, RigHelm's built-in server, flrig's emulation...).
 *  One request at a time: a Set answers `RPRT n`, a Get answers its values or `RPRT -n`. */
class RigctldRig internal constructor(private val stream: ByteStream, override val name: String) : Rig {
    private val inbox = Inbox(stream)
    // Answers stay paired with their requests.
    private val exclusive = Mutex()
    @Volatile private var keyed = false

    companion object {
        const val DEFAULT_PORT = 4532

        suspend fun connect(host: String, port: Int = DEFAULT_PORT): RigctldRig {
            val s = TCPStream.connect(host, port, 4.0)
            val rig = RigctldRig(s, "rigctld $host:$port")
            try {
                rig.status()
            } catch (e: Exception) {
                rig.close()
                throw e
            }
            return rig
        }

        internal fun label(m: String): String = when (m) {
            "PKTUSB" -> "DATA-U"
            "PKTLSB" -> "DATA-L"
            "PKTFM" -> "DATA-FM"
            "PKTAM" -> "DATA-AM"
            "RTTYR" -> "RTTY-U"
            "RTTY" -> "RTTY-L"
            else -> m
        }
    }

    private suspend fun lines(cmd: String, count: Int): List<String> {
        stream.write("$cmd\n")
        val out = mutableListOf<String>()
        while (out.size < count) {
            val l = inbox.line(3.0, "waiting for rigctld to answer $cmd")
            if (l.startsWith("RPRT ")) throw RigException.Rejected(cmd, l.drop(5).toIntOrNull() ?: -1)
            out += l
        }
        return out
    }

    private suspend fun set(cmd: String) {
        stream.write("$cmd\n")
        val l = inbox.line(3.0, "waiting for rigctld to answer $cmd")
        val code = if (l.startsWith("RPRT ")) l.drop(5).toIntOrNull() ?: -1 else -1
        if (code != 0) throw RigException.Rejected(cmd, code)
    }

    override suspend fun status(): RigStatus = exclusive.withLock {
        val f = lines("f", 1)
        val m = lines("m", 2)
        val t = lines("t", 1)
        RigStatus(f[0].toDoubleOrNull()?.toLong(), label(m[0]), t[0] != "0")
    }

    override suspend fun setFrequency(hz: Long) = exclusive.withLock { set("F $hz") }

    // Passband 0: the radio's default width for the mode.
    override suspend fun setMode(mode: RigMode) =
        exclusive.withLock { set("M ${if (mode == RigMode.DATA_FM) "PKTFM" else "PKTUSB"} 0") }

    override suspend fun setPTT(on: Boolean) {
        keyed = on
        exclusive.withLock { set("T ${if (on) 1 else 0}") }
    }

    override suspend fun tune() = exclusive.withLock { set("G TUNE") }

    override suspend fun close() {
        if (keyed) {
            keyed = false
            runCatching { stream.write("T 0\n") }
            delay(100)
        }
        inbox.cancel()
        stream.close()
    }
}
