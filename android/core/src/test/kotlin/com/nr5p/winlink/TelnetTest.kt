package com.nr5p.winlink

import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

/** The CMS telnet login against a scripted server (the live CMS is not contacted). */
class TelnetTest {
    @Test fun loginThenB2F() = runBlocking {
        val (client, srv) = PipeStream.pair()
        val login = async { CMSTelnet.login(client, "n0tst") {} }
        srv.write("Welcome to the Winlink CMS\r\nCallsign :")
        val rd = StreamReader(srv)
        assertEquals("N0TST\r", String(rd.readUntil(13)))
        // Password prompt and the start of the handshake arrive in one chunk.
        srv.write("Password :\r[WL2K-5.0-B2FWIHJM$]\r")
        assertEquals("CMSTelnet\r", String(rd.readUntil(13)))
        val rest = login.await()
        assertEquals("[WL2K-5.0-B2FWIHJM$]\r", String(rest))

        // The leftover bytes feed the B2F session.
        val s = B2FSession("N0TST", CMSTelnet.TARGET_CALL, "EM10", null)
        val done = async { s.exchange(PrefixedStream(client, rest)) }
        srv.write("CMS >\r")
        val lines = (0 until 4).map { String(rd.readUntil(13)) }
        assertEquals("FF\r", lines.last())
        assertEquals("; WL2K DE N0TST (EM10)\r", lines[2])
        srv.write("FQ\r")
        done.await()
        Unit
    }

    @Test fun closedBeforePrompt() = runBlocking {
        val (client, srv) = PipeStream.pair()
        val login = async { runCatching { CMSTelnet.login(client, "N0TST") {} } }
        srv.write("Callsign :")
        srv.close()
        if (login.await().isSuccess) fail("login succeeded on a closed stream")
    }
}
