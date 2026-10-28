package com.nr5p.winlink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LinkSpeedTest {
    @Test fun parseBitrateLines() {
        assertEquals(LinkSpeed(7, 549, true, "6 carriers · QPSK"), LinkSpeed.parse("(7)  549 bps TX", VARAMode.HF, "2300"))
        assertEquals(LinkSpeed(4, 175, false, "FSK"), LinkSpeed.parse(" (4)  175 bps RX", VARAMode.HF, "2300"))
        assertEquals("OFDM 49 carriers · 32QAM", LinkSpeed.parse("(16)  7050 bps TX", VARAMode.HF, "2300")?.modulation)
        assertEquals("2 carriers · BPSK", LinkSpeed.parse("(4)  175 bps TX", VARAMode.HF, "500")?.modulation)
        assertEquals("13 carriers · QPSK", LinkSpeed.parse("(10)  2400 bps TX", VARAMode.HF, "2750")?.modulation)
        assertNull(LinkSpeed.parse("(3)  1200 bps TX", VARAMode.FM, null)?.modulation)
        assertEquals(1200, LinkSpeed.parse("(3)  1200 bps TX", VARAMode.FM, null)?.bps)
        assertNull(LinkSpeed.parse("garbage", VARAMode.HF, "2300"))
        assertNull(LinkSpeed.modulation(17, "2300"))
    }
}
