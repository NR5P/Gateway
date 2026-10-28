package com.nr5p.winlink

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ServerSocket
import java.util.Collections
import kotlin.concurrent.thread

/** VARAModem against a scripted modem on loopback: setup, a call, data both ways, disconnect. */
class VARAModemTest {
    @Test fun callExchangeAndDisconnect() = runBlocking(Dispatchers.IO) {
        val cmdSrv = ServerSocket(0)
        val dataSrv = ServerSocket(cmdSrv.localPort + 1)
        val got = Collections.synchronizedList(mutableListOf<String>())
        val received = java.io.ByteArrayOutputStream()
        val modem = thread {
            val c = cmdSrv.accept()
            val d = dataSrv.accept()
            val cin = c.getInputStream()
            val cout = c.getOutputStream()
            fun reply(s: String) = cout.write("$s\r".toByteArray())
            val line = StringBuilder()
            while (true) {
                val b = cin.read()
                if (b < 0) break
                if (b != 13) {
                    line.append(b.toChar())
                    continue
                }
                val l = line.toString()
                line.clear()
                got += l
                when {
                    l == "VERSION" -> reply("VERSION 4.8.9")
                    l == "WINLINK SESSION" -> reply("WRONG")
                    l.startsWith("CONNECT ") -> {
                        reply("PTT ON")
                        reply("PTT OFF")
                        reply("CONNECTED N0CALL W1AW-10 2300")
                        d.getOutputStream().write("[WL2K-5.0-B2FWIHJM$]\r".toByteArray())
                        // What the client writes after CONNECTED.
                        thread {
                            val buf = ByteArray(100)
                            val n = d.getInputStream().read(buf)
                            synchronized(received) { received.write(buf, 0, n) }
                            reply("BUFFER $n")
                            reply("BUFFER 0")
                        }
                    }
                    l == "DISCONNECT" -> reply("DISCONNECTED")
                    else -> reply("OK")
                }
            }
            c.close()
            d.close()
        }

        val events = Collections.synchronizedList(mutableListOf<VARAEvent>())
        val m = VARAModem(VARAConfig(commandPort = cmdSrv.localPort, mycall = "n0call"))
        m.onEvent = { events += it }
        withTimeout(10_000) {
            m.open()
            assertEquals("4.8.9", m.version)
            assertEquals(VARALinkState.Idle, m.state)
            val link = m.connect("w1aw-10")
            assertEquals(VARALinkState.Connected("N0CALL", "W1AW-10", "2300"), m.state)
            assertEquals("[WL2K-5.0-B2FWIHJM$]\r", String(link.read()))
            link.write("hello")
            link.flush()
            assertEquals("hello", synchronized(received) { received.toString() })
            m.disconnect()
            assertEquals(VARALinkState.Idle, m.state)
            assertEquals(0, link.read().size)
            m.close()
        }
        modem.join(2000)
        cmdSrv.close()
        dataSrv.close()
        assertTrue(got.containsAll(listOf("MYCALL N0CALL", "BW2300", "CONNECT N0CALL W1AW-10", "DISCONNECT")))
        assertTrue(events.contains(VARAEvent.Ptt(true)))
        assertTrue(events.contains(VARAEvent.State(VARALinkState.Closed)))
    }

    @Test fun notAVARAModem() = runBlocking(Dispatchers.IO) {
        val cmdSrv = ServerSocket(0)
        val dataSrv = ServerSocket(cmdSrv.localPort + 1)
        thread {
            val c = cmdSrv.accept()
            dataSrv.accept()
            c.getInputStream().read(ByteArray(100))
            c.getOutputStream().write("WRONG\r".toByteArray())
            Thread.sleep(500)
            c.close()
        }
        val m = VARAModem(VARAConfig(commandPort = cmdSrv.localPort, mycall = "N0CALL"))
        val e = async { runCatching { m.open() }.exceptionOrNull() }.await()
        assertTrue("$e", e is VARAException.NotVARA)
        assertEquals(VARALinkState.Closed, m.state)
        cmdSrv.close()
        dataSrv.close()
    }
}
