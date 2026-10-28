package com.nr5p.winlink.rig

import java.util.Locale
import kotlin.math.roundToLong

/** The radio as last read back from it. */
data class RigStatus(
    /** VFO frequency in Hz, null until it has been read. */
    val frequency: Long? = null,
    /** The radio's mode, as the front panel shows it ("DATA-U", "USB", "FM", ...). */
    val mode: String? = null,
    val transmitting: Boolean = false,
)

/** The modes Gateway sets: the radio's data mode, so audio comes from the USB/rear input
 *  and the mic and speech processor stay out of the way. */
enum class RigMode(val raw: String) { DATA_USB("DATA-U"), DATA_FM("DATA-FM") }

/** A radio under CAT control, through RigHelm or hamlib's rigctld. */
interface Rig {
    /** What is being controlled, for the log ("RigHelm Shack: ftdx3000"). */
    val name: String
    suspend fun status(): RigStatus
    suspend fun setFrequency(hz: Long)
    suspend fun setMode(mode: RigMode)
    /** Keys or un-keys the transmitter. Sent at once: the modem's audio is about to follow. */
    suspend fun setPTT(on: Boolean)
    /** Starts the antenna tuner (the radio transmits a carrier while it tunes). */
    suspend fun tune()
    /** Un-keys if keyed, then hangs up. */
    suspend fun close()
}

open class RigException(message: String) : Exception(message) {
    class Denied(why: String) : RigException("RigHelm refused the connection: $why")
    class NotRigHelm(got: String) : RigException("not a RigHelm station (got $got)")
    class Rejected(val command: String, val code: Int) : RigException(
        if (code == -9) "the radio refused $command: transmit is blocked there" else "rigctld answered $code to $command",
    )
    class NoAnswer(what: String) : RigException("no answer from the radio to $what")
    class NotConfirmed(what: String) : RigException("the radio did not confirm $what")
}

/** Frequencies as people write them: "14105.0" kHz, "14.105" MHz or "14105000" Hz. */
object DialFrequency {
    fun parse(text: String): Long? {
        val t = text.trim().replace(",", "")
        val v = t.toDoubleOrNull() ?: return null
        if (v <= 0) return null
        val hz = if (v < 1_000) v * 1_000_000 else if (v < 1_000_000) v * 1_000 else v
        if (hz !in 100_000.0..6_000_000_000.0) return null
        return hz.roundToLong()
    }

    /** 14105000 -> "14.105.000" */
    fun format(hz: Long): String =
        String.format(Locale.US, "%d.%03d.%03d", hz / 1_000_000, hz / 1_000 % 1_000, hz % 1_000)
}
