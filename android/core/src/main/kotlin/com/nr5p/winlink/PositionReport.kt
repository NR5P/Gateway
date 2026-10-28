package com.nr5p.winlink

import java.time.Instant
import java.util.Locale
import kotlin.math.abs

/** A Winlink position report: a message to QTH that puts the station on the Winlink map
 *  (ported from wl2k-go's catalog package). */
data class PositionReport(
    val date: Instant = Instant.now(),
    val latitude: Double,
    val longitude: Double,
    /** Up to 80 characters. */
    val comment: String = "",
) {
    fun message(mycall: String): Message {
        val body = StringBuilder("DATE: ${Message.formatDate(date)}\r\n")
        body.append("LATITUDE: ${minutes(latitude, true)}\r\n")
        body.append("LONGITUDE: ${minutes(longitude, false)}\r\n")
        val c = comment.trim()
        if (c.isNotEmpty()) body.append("COMMENT: ${c.take(80)}\r\n")
        val m = Message(mycall, "Position Report", date)
        m.setBody(body.toString())
        m.subject = "POSITION REPORT"
        m.addTo("QTH")
        return m
    }

    companion object {
        /** Degrees and decimal minutes: 60.132 -> "60-07.9200N", -60.5 -> "060-30.0000W". */
        fun minutes(dec: Double, latitude: Boolean): String {
            val sign = if (dec > 0) (if (latitude) "N" else "E") else if (dec < 0) (if (latitude) "S" else "W") else " "
            val deg = dec.toInt()
            val min = abs((dec - deg) * 60)
            return String.format(Locale.US, if (latitude) "%02d-%07.4f%s" else "%03d-%07.4f%s", abs(deg), min, sign)
        }
    }
}
