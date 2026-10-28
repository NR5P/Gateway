package com.nr5p.winlink.rig

import com.nr5p.winlink.PipeStream
import com.nr5p.winlink.StreamReader
import com.nr5p.winlink.write
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Collections

/** Rig control against scripted RigHelm and rigctld servers. */
class RigTest {
    @Test fun dialFrequency() {
        assertEquals(14_105_000L, DialFrequency.parse("14105.0"))
        assertEquals(14_105_000L, DialFrequency.parse("14.105"))
        assertEquals(7_101_500L, DialFrequency.parse("7,101.5"))
        assertEquals(145_050_000L, DialFrequency.parse("145050000"))
        assertNull(DialFrequency.parse("abc"))
        assertEquals("14.105.000", DialFrequency.format(14_105_000))
    }

    @Test fun rigHelmProof() {
        // Same construction as righelm's remote.rs (HMAC-SHA256, hex).
        assertEquals("-", RigHelmRig.proof("", "ab", "CAT"))
        assertEquals(64, RigHelmRig.proof("secret", "0011223344556677", "CAT").length)
    }

    @Test fun beacon() {
        val b = RigDiscovery.parseBeacon("FTDX3000-REMOTE v1;id=a1b2;name=Shack;port=4533;audio=1;auth=1;mic=0;radio=connected", "10.0.0.5")
        assertEquals("a1b2", b?.first)
        assertEquals(RigEndpoint(RigEndpoint.Kind.RIGHELM, "10.0.0.5", 4533, "Shack", true, "connected"), b?.second)
        assertNull(RigDiscovery.parseBeacon("hello", "10.0.0.5"))
    }

    private class Radio {
        @Volatile var fa = "FA07101500;"
        @Volatile var md = "MD02;"
        @Volatile var tx = "TX0;"
    }

    /** A RigHelm station: login, then FTDX3000 CAT both ways. */
    @Test fun rigHelmSession() = runBlocking {
        val (client, srv) = PipeStream.pair()
        val rd = StreamReader(srv)
        val open = async { RigHelmRig.open(client, "pw") }
        srv.write("FTDX3000-REMOTE v1 00112233 Shack\n")
        assertEquals("HELLO CAT ${RigHelmRig.proof("pw", "00112233", "CAT")}\n", String(rd.readUntil(10)))
        srv.write("OK 00000000000000aa 4533 24000 ftdx3000\n")

        val radio = Radio()
        // Answer what the client asks, like the radio.
        val answer = launch {
            runCatching {
                while (true) {
                    val f = String(rd.readUntil(';'.code))
                    when {
                        f == "FA;" -> srv.write(radio.fa)
                        f == "MD0;" -> srv.write(radio.md)
                        f == "TX;" -> srv.write(radio.tx)
                        f.startsWith("FA") -> radio.fa = f
                        f.startsWith("MD0") -> radio.md = f
                        f == "TX1;" -> radio.tx = "TX2;"
                        f == "TX0;" -> radio.tx = "TX0;"
                    }
                }
            }
        }
        val rig = open.await()
        assertEquals("RigHelm Shack: ftdx3000", rig.name)
        assertEquals(7_101_500L, rig.status().frequency)

        rig.setFrequency(14_105_000)
        rig.setMode(RigMode.DATA_USB)
        var s = rig.status()
        assertEquals(14_105_000L, s.frequency)
        assertEquals("DATA-U", s.mode)

        rig.setPTT(true)
        delay(200)
        s = rig.status()
        assertTrue(s.transmitting)
        // Closing while keyed un-keys first.
        rig.close()
        delay(150)
        assertEquals("TX0;", radio.tx)
        answer.cancel()
    }

    @Test fun rigHelmDenied() = runBlocking {
        val (client, srv) = PipeStream.pair()
        val open = async { runCatching { RigHelmRig.open(client, "bad") } }
        srv.write("FTDX3000-REMOTE v1 00112233 Shack\n")
        StreamReader(srv).readUntil(10)
        srv.write("DENIED wrong password\n")
        val e = open.await().exceptionOrNull()
        assertTrue("$e", e is RigException.Denied)
        assertEquals("RigHelm refused the connection: wrong password", e!!.message)
    }

    @Test fun rigctld() = runBlocking {
        val (client, srv) = PipeStream.pair()
        val rig = RigctldRig(client, "rigctld test")
        val rd = StreamReader(srv)
        val sent = Collections.synchronizedList(mutableListOf<String>())
        val server = launch {
            runCatching {
                var freq = "7101500"
                var ptt = "0"
                while (true) {
                    val l = String(rd.readUntil(10)).trimEnd('\n', '\r')
                    sent += l
                    when (l) {
                        "f" -> srv.write("$freq\n")
                        "m" -> srv.write("PKTUSB\n3000\n")
                        "t" -> srv.write("$ptt\n")
                        "G TUNE" -> srv.write("RPRT -9\n")
                        else -> {
                            if (l.startsWith("F ")) freq = l.drop(2)
                            if (l.startsWith("T ")) ptt = l.drop(2)
                            srv.write("RPRT 0\n")
                        }
                    }
                }
            }
        }
        // Requests from several coroutines at once still pair with their answers.
        val a = async { rig.setFrequency(14_105_000) }
        val b = async { rig.status() }
        a.await()
        b.await()
        rig.setMode(RigMode.DATA_USB)
        rig.setPTT(true)
        val s = rig.status()
        assertEquals(14_105_000L, s.frequency)
        assertEquals("DATA-U", s.mode)
        assertTrue(s.transmitting)
        val e = runCatching { rig.tune() }.exceptionOrNull()
        assertTrue("$e", e is RigException.Rejected && e.code == -9 && e.command == "G TUNE")
        rig.close()
        delay(150)
        assertEquals("T 0", sent.last())
        assertTrue(sent.contains("M PKTUSB 0"))
        server.cancel()
    }
}
