package com.nr5p.winlink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.Instant

class GatewayDirectoryTest {
    @Test fun parseKeepsPublicVARA() {
        val json = """
        {"ServerName":"x","ErrorCode":0,"Gateways":[
         {"Callsign":"W1AW-10","Latitude":41.7,"Longitude":-72.7,"LastStatus":"Sun, 19 Apr 2026 14:51:00 UTC","Comments":"",
          "GatewayChannels":[
           {"SupportedModes":"VARA 2750","Frequency":7103500,"Gridsquare":"FN31","OperatingHours":"00-23","ServiceCode":"PUBLIC"},
           {"SupportedModes":"Packet 1200","Frequency":145010000,"ServiceCode":"PUBLIC"},
           {"SupportedModes":"VARA","Frequency":14108500,"ServiceCode":"EMCOMM"},
           {"SupportedModes":"VARA FM WIDE","Frequency":145090000,"ServiceCode":"PUBLIC"},
           {"SupportedModes":"VARA 2750","Frequency":7103500,"ServiceCode":"PUBLIC"}]},
         {"Callsign":"N0PKT-10","Latitude":40,"Longitude":-100,
          "GatewayChannels":[{"SupportedModes":"Packet 1200","Frequency":145010000}]}]}
        """
        val g = GatewayDirectory.parse(json)
        assertEquals(listOf("W1AW-10"), g.map { it.callsign })
        assertEquals(2, g[0].channels.size)
        val hf = g[0].channels[0]
        val fm = g[0].channels[1]
        assertEquals(7_102_000, hf.dial)
        assertEquals("2750", hf.bandwidth)
        assertEquals("40m", hf.band)
        assertTrue(fm.isFM)
        assertEquals(145_090_000, fm.dial)
        assertNull(fm.bandwidth)
        assertNotNull(g[0].lastStatus)
    }

    @Test fun maidenhead() {
        val em10 = Maidenhead.coordinate("EM10")!!
        assertEquals(30.5, em10.lat, 0.01)
        assertEquals(-97.0, em10.lon, 0.01)
        val fn31pr = Maidenhead.coordinate("FN31pr")!!
        assertEquals(41.73, fn31pr.lat, 0.03)
        assertEquals(-72.71, fn31pr.lon, 0.05)
        assertNull(Maidenhead.coordinate("ZZ99"))
        // Austin to Newington CT, about 2,500 km, heading north-east.
        assertEquals(2_530.0, Maidenhead.distance(em10, fn31pr), 60.0)
        assertEquals(55.0, Maidenhead.bearing(em10, fn31pr), 5.0)
    }

    @Test fun bundledList() {
        val g = GatewayDirectory.parse(File("../../Gateway/gateways.json").readText())
        assertTrue(g.size > 1000)
    }
}

class PositionReportTest {
    @Test fun minutes() {
        // wl2k-go's vectors.
        val lat = mapOf(-4.974 to "04-58.4400S", -0.5 to "00-30.0000S", 0.0 to "00-00.0000 ", 0.5 to "00-30.0000N", 60.132 to "60-07.9200N")
        val lon = mapOf(
            -180.0 to "180-00.0000W", -60.5 to "060-30.0000W", -0.5 to "000-30.0000W", 0.0 to "000-00.0000 ",
            3.5 to "003-30.0000E", 153.5 to "153-30.0000E", 180.0 to "180-00.0000E",
        )
        for ((d, s) in lat) assertEquals(s, PositionReport.minutes(d, true))
        for ((d, s) in lon) assertEquals(s, PositionReport.minutes(d, false))
    }

    @Test fun message() {
        val d = Instant.ofEpochSecond(1_800_000_000)
        val m = PositionReport(d, 40.704, -73.945, "QRV 145.500").message("N0TST")
        assertEquals(listOf("QTH"), m.to.map { it.addr })
        assertEquals("POSITION REPORT", m.subject)
        assertEquals("Position Report", m.type)
        assertEquals(
            "DATE: ${Message.formatDate(d)}\r\nLATITUDE: 40-42.2400N\r\nLONGITUDE: 073-56.7000W\r\nCOMMENT: QRV 145.500\r\n",
            String(m.body),
        )
        m.bytes()
    }
}
