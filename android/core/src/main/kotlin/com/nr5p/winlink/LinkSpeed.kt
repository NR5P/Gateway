package com.nr5p.winlink

/** The speed of a VARA link, from the modem's `BITRATE (7)  549 bps TX` lines. */
data class LinkSpeed(
    /** The speed level, 1 (slowest) and up. */
    val level: Int,
    val bps: Int,
    /** True while this station is sending, false while it is receiving. */
    val transmitting: Boolean,
    /** The waveform at this level, such as "6 carriers · QPSK"; null for VARA FM. */
    val modulation: String?,
) {
    companion object {
        /** Parses the text after `BITRATE`, e.g. "(7)  549 bps TX", for a link in [mode] at [bandwidth] Hz. */
        fun parse(text: String, mode: VARAMode, bandwidth: String?): LinkSpeed? {
            val t = text.trim()
            val close = t.indexOf(')')
            if (!t.startsWith("(") || close < 0) return null
            val level = t.substring(1, close).toIntOrNull() ?: return null
            val rest = t.substring(close + 1).split(" ").filter { it.isNotEmpty() }
            val bps = rest.firstOrNull()?.toIntOrNull() ?: return null
            val modulation = if (mode == VARAMode.HF) modulation(level, bandwidth ?: "2300") else null
            return LinkSpeed(level, bps, rest.lastOrNull() == "TX", modulation)
        }

        /** The waveform VARA HF uses at a level, as xara's level tables name it. */
        fun modulation(level: Int, bandwidth: String): String? {
            val table = when (bandwidth) {
                "500" -> HF500
                "2750" -> HF2750
                else -> HF2300
            }
            return table.getOrNull(level - 1)
        }

        private val HF500 = listOf(
            "FSK", "FSK", "FSK", "2 carriers · BPSK", "2 carriers · QPSK", "3 carriers · QPSK",
            "OFDM 11 carriers · QPSK", "OFDM 11 carriers · QPSK", "OFDM 11 carriers · QPSK",
            "OFDM 11 carriers · 8PSK", "OFDM 11 carriers · 8PSK", "OFDM 11 carriers · 16QAM", "OFDM 11 carriers · 32QAM",
        )
        private val HF2300 = listOf(
            "FSK", "FSK", "FSK", "FSK", "3 carriers · QPSK", "4 carriers · QPSK", "6 carriers · QPSK",
            "8 carriers · QPSK", "10 carriers · QPSK", "OFDM 49 carriers · QPSK", "OFDM 49 carriers · QPSK",
            "OFDM 49 carriers · QPSK", "OFDM 49 carriers · 8PSK", "OFDM 49 carriers · 8PSK",
            "OFDM 49 carriers · 16QAM", "OFDM 49 carriers · 32QAM",
        )
        private val HF2750 = listOf(
            "FSK", "FSK", "FSK", "FSK", "3 carriers · QPSK", "4 carriers · QPSK", "6 carriers · QPSK",
            "8 carriers · QPSK", "10 carriers · QPSK", "13 carriers · QPSK", "OFDM 59 carriers · QPSK",
            "OFDM 59 carriers · QPSK", "OFDM 59 carriers · QPSK", "OFDM 59 carriers · 8PSK",
            "OFDM 59 carriers · 8PSK", "OFDM 59 carriers · 16QAM", "OFDM 59 carriers · 32QAM",
        )
    }
}
