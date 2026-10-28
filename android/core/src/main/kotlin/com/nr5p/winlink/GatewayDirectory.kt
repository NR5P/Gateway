package com.nr5p.winlink

import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder
import java.time.Instant
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/** A Winlink RMS gateway and its VARA channels, from the Winlink gateway status list
 *  (api.winlink.org/gateway/status.json, the list Pat and Winlink Express use). */
data class RMSGateway(
    val callsign: String,
    val latitude: Double,
    val longitude: Double,
    val lastStatus: Instant?,
    val comments: String,
    val channels: List<RMSChannel>,
) {
    val id: String get() = callsign
}

data class RMSChannel(
    /** As listed: "VARA", "VARA 500", "VARA 2750", "VARA FM", "VARA FM WIDE". */
    val modes: String,
    /** The listed (centre) frequency in Hz. */
    val frequency: Int,
    val grid: String,
    /** UTC hours, e.g. "00-23". */
    val hours: String,
    val antenna: String,
    val serviceCode: String,
) {
    val id: String get() = "$modes@$frequency"

    val isFM: Boolean get() = modes.uppercase().contains("FM")

    /** The radio's dial: the listed frequency is the centre of the signal, 1500 Hz above an
     *  HF (USB) dial; FM channels are listed at their dial frequency (as in Pat). */
    val dial: Int get() = if (isFM) frequency else frequency - 1500

    /** VARA HF bandwidth: "VARA 500" -> 500, "VARA 2750" -> 2750, plain "VARA" -> 2300. */
    val bandwidth: String?
        get() = when {
            isFM -> null
            modes.contains("500") -> "500"
            modes.contains("2750") -> "2750"
            else -> "2300"
        }

    val band: String
        get() {
            val mhz = dial / 1e6
            return BANDS.firstOrNull { mhz in it.second }?.first ?: String.format(Locale.US, "%.3f MHz", mhz)
        }

    companion object {
        val BANDS = listOf(
            "160m" to 1.8..2.0, "80m" to 3.5..4.0, "60m" to 5.2..5.5, "40m" to 7.0..7.3, "30m" to 10.1..10.2,
            "20m" to 14.0..14.4, "17m" to 18.0..18.2, "15m" to 21.0..21.5, "12m" to 24.8..25.0, "10m" to 28.0..30.0,
            "6m" to 50.0..54.0, "2m" to 144.0..148.0, "1.25m" to 219.0..225.0, "70cm" to 420.0..450.0,
        )
    }
}

class GatewayDirectoryException(message: String) : IOException(message)

object GatewayDirectory {
    private val lastStatusFormat = DateTimeFormatter.ofPattern("EEE, dd MMM yyyy HH:mm:ss zzz", Locale.US)

    /** Parses the status list (or the bundled copy, which has the same shape), keeping VARA
     *  channels with public access. */
    fun parse(json: String): List<RMSGateway> {
        val gateways = JSONObject(json).getJSONArray("Gateways")
        val out = mutableListOf<RMSGateway>()
        for (i in 0 until gateways.length()) {
            val g = gateways.getJSONObject(i)
            val chans = g.getJSONArray("GatewayChannels")
            val list = mutableListOf<RMSChannel>()
            for (j in 0 until chans.length()) {
                val c = chans.getJSONObject(j)
                val modes = c.getString("SupportedModes")
                val service = c.optStr("ServiceCode")
                if (!modes.uppercase().startsWith("VARA") || !(service ?: "PUBLIC").contains("PUBLIC")) continue
                list += RMSChannel(
                    modes, c.getDouble("Frequency").toInt(), c.optStr("Gridsquare") ?: "",
                    c.optStr("OperatingHours") ?: "", c.optStr("Antenna") ?: "", service ?: "",
                )
            }
            // The list repeats some channels (one entry per service code).
            val ch = list.sortedBy { it.frequency }.distinctBy { it.id }
            val lat = g.getDouble("Latitude")
            val lon = g.getDouble("Longitude")
            if (ch.isEmpty() || abs(lat) > 90 || abs(lon) > 180) continue
            val last = g.optStr("LastStatus")?.let {
                try { ZonedDateTime.parse(it, lastStatusFormat).toInstant() } catch (_: Exception) { null }
            }
            out += RMSGateway(g.getString("Callsign"), lat, lon, last, g.optStr("Comments") ?: "", ch)
        }
        return out
    }

    private fun JSONObject.optStr(key: String): String? = if (isNull(key)) null else optString(key)

    /** Downloads the current list. The Winlink API wants a key issued to the program by the
     *  Winlink Development Team (one per program; ask them at winlink.org). Blocking. */
    fun fetch(key: String): String {
        val conn = URI("https://api.winlink.org/gateway/status.json").toURL().openConnection() as HttpURLConnection
        try {
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
            val form = listOf("Mode" to "AnyAll", "HistoryHours" to "48", "ServiceCodes" to "PUBLIC", "key" to key)
                .joinToString("&") { (k, v) -> "$k=${URLEncoder.encode(v, "UTF-8")}" }
            conn.outputStream.use { it.write(form.toByteArray()) }
            if (conn.responseCode != 200) throw GatewayDirectoryException("the Winlink API answered HTTP ${conn.responseCode}")
            val data = conn.inputStream.use { String(it.readBytes()) }
            // A bad key comes back as 200 with an error status and no gateways.
            if (parse(data).isEmpty()) throw GatewayDirectoryException("the Winlink API returned no gateways (check the API key)")
            return data
        } finally {
            conn.disconnect()
        }
    }
}

data class LatLon(val lat: Double, val lon: Double)

/** Maidenhead grid locators and great-circle distances. */
object Maidenhead {
    /** The centre of a 4- or 6-character locator ("EM10", "EM10dk"). */
    fun coordinate(locator: String): LatLon? {
        val c = locator.uppercase()
        if (c.length < 4 || c.length % 2 != 0) return null
        val a = c[0].code
        val b = c[1].code
        if (a !in 65..82 || b !in 65..82 || !c[2].isDigit() || !c[3].isDigit()) return null
        var lon = (a - 65) * 20.0 - 180 + c[2].digitToInt() * 2
        var lat = (b - 65) * 10.0 - 90 + c[3].digitToInt()
        if (c.length >= 6 && c[4].code in 65..88 && c[5].code in 65..88) {
            lon += (c[4].code - 65) * (2.0 / 24) + 1.0 / 24
            lat += (c[5].code - 65) * (1.0 / 24) + 0.5 / 24
        } else {
            lon += 1
            lat += 0.5
        }
        return LatLon(lat, lon)
    }

    /** Great-circle distance in km. */
    fun distance(a: LatLon, b: LatLon): Double {
        val r = 6371.0
        val p = PI / 180
        val dlat = (b.lat - a.lat) * p
        val dlon = (b.lon - a.lon) * p
        val h = sin(dlat / 2) * sin(dlat / 2) + cos(a.lat * p) * cos(b.lat * p) * sin(dlon / 2) * sin(dlon / 2)
        return 2 * r * asin(min(1.0, sqrt(h)))
    }

    /** Initial bearing in degrees from north. */
    fun bearing(a: LatLon, b: LatLon): Double {
        val p = PI / 180
        val y = sin((b.lon - a.lon) * p) * cos(b.lat * p)
        val x = cos(a.lat * p) * sin(b.lat * p) - sin(a.lat * p) * cos(b.lat * p) * cos((b.lon - a.lon) * p)
        return (atan2(y, x) / p + 360) % 360
    }
}
