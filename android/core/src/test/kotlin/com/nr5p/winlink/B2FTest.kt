// Most cases here are ported from la5nta/wl2k-go's fbb tests (MIT), by way of the Swift WinlinkKit tests.

package com.nr5p.winlink

import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.time.Instant

class MemoryMailbox(val out: List<Message> = emptyList()) : Mailbox {
    val inbox = mutableListOf<Message>()
    val sent = mutableListOf<Pair<String, Boolean>>()
    val deferred = mutableListOf<String>()
    var answer = ProposalAnswer.ACCEPT

    override fun outbound(forwarders: List<Address>): List<Message> {
        val sentMIDs = sent.map { it.first }.toSet()
        return out.filter { it.mid !in sentMIDs }
    }

    override fun markSent(mid: String, rejected: Boolean) { sent += mid to rejected }
    override fun markDeferred(mid: String) { deferred += mid }
    override fun answer(proposal: Proposal) = if (inbox.any { it.mid == proposal.mid }) ProposalAnswer.REJECT else answer
    override fun receive(message: Message) { inbox += message }
}

/** Reads CR-terminated lines from the far end of a pipe. */
internal class LineReader(s: ByteStream) {
    val r = StreamReader(s)
    suspend fun line(): String = String(r.readUntil(13))
}

fun makeMessage(from: String = "N0CALL", to: String = "LA5NTA", subject: String = "Hello", body: String = "Hello world"): Message {
    val m = Message(from)
    m.addTo(to)
    m.subject = subject
    m.setBody(body)
    return m
}

private fun sum(s: String) = s.toByteArray().sumOf { it.u }

class B2FTest {
    @Test fun secureLoginResponse() {
        assertEquals("72768415", SecureLogin.response("23753528", "FOOBAR"))
        assertEquals("95074758", SecureLogin.response("23753528", "FooBar"))
    }

    @Test fun parseFW() {
        assertEquals(listOf(Address.parse("LA5NTA")), B2FSession.parseFW(";FW: LA5NTA"))
        assertEquals(listOf(Address.parse("LE1OF"), Address.parse("LA5NTA")), B2FSession.parseFW(";FW: LE1OF LA5NTA"))
        assertEquals(listOf(Address(addr = "LA4TTA")), B2FSession.parseFW(";FW: la4tta"))
        assertEquals(listOf(Address(addr = "LA4TTA")), B2FSession.parseFW(";FW: LA4TTA|12345678"))
    }

    @Test fun parsePM() {
        val pm = PendingMessage.parse(";PM: LA5NTA FOOBARBAZ 869 SERVICE@winlink.org Your new Winlink Account")
        assertEquals(
            PendingMessage("FOOBARBAZ", Address.parse("LA5NTA"), Address.parse("SERVICE@winlink.org"), "Your new Winlink Account", 869),
            pm,
        )
    }

    @Test fun loginFailure() {
        assertTrue(B2FException.Remote("[1] Secure login failed - account password does not match. - Disconnecting (88.90.2.192)").isLoginFailure)
        assertFalse(B2FException.ConnectionLost().isLoginFailure)
    }

    @Test fun parseProposalAnswer() {
        fun five() = (0 until 5).map { Proposal.outbound("M$it", "t", ByteArray(5000) { 65 }) }
        var p = five()
        Proposal.applyAnswer("FS YLA3350RH", p)
        assertEquals(
            listOf(ProposalAnswer.ACCEPT, ProposalAnswer.DEFER, ProposalAnswer.ACCEPT, ProposalAnswer.REJECT, ProposalAnswer.DEFER),
            p.map { it.answer },
        )
        assertEquals(if (3350 < p[2].compressedData.size) 3350 else 0, p[2].offset)
        p = five()
        Proposal.applyAnswer("FS +=!3350-+", p)
        assertEquals(
            listOf(ProposalAnswer.ACCEPT, ProposalAnswer.DEFER, ProposalAnswer.ACCEPT, ProposalAnswer.REJECT, ProposalAnswer.ACCEPT),
            p.map { it.answer },
        )
        assertThrows { Proposal.applyAnswer("FS ++++++", p) }
        assertThrows { Proposal.applyAnswer("FS X", p) }
    }

    @Test fun parseProposal() {
        val p = Proposal.parse("FC EM TJKYEIMMHSRB 527 123 0")
        assertEquals("TJKYEIMMHSRB", p.mid)
        assertEquals(527, p.size)
        assertEquals(123, p.compressedSize)
        assertThrows { Proposal.parse("FC XX TJKYEIMMHSRB 527 123 0") }
        assertThrows { Proposal.parse("FC EM TJK 527") }
    }

    @Test fun sortProposals() {
        fun p(subject: String) = Proposal.of(makeMessage(subject = subject, body = "Satisfies validation"))
        val sorted = Proposal.sorted(
            listOf(
                p("Just a test"), p("Re://WL2K O/Very important"), p("//WL2K R/Read this sometime, or don't"),
                p("//WL2K P/ Pretty important"), p("//WL2K Z/The world is on fire!"),
            ),
        )
        assertEquals(
            listOf(
                "//WL2K Z/The world is on fire!", "Re://WL2K O/Very important", "//WL2K P/ Pretty important",
                "Just a test", "//WL2K R/Read this sometime, or don't",
            ),
            sorted.map { it.title },
        )
    }

    // Sessions against a scripted CMS

    @Test fun sessionCMS() = runBlocking {
        val (client, srv) = PipeStream.pair()
        val s = B2FSession("LA5NTA", "LA1B-10", "JO39EQ", null)
        s.userAgent = B2FSession.UserAgent("wl2kgo", "0.1a")
        val done = async { s.exchange(client) }
        srv.write("[WL2K-2.8.4.8-B2FWIHJM$]\rFoobar should be ignored\rTest CMS >\r")
        val rd = LineReader(srv)
        for (want in listOf(";FW: LA5NTA\r", "[wl2kgo-0.1a-B2FHM$]\r", "; LA1B-10 DE LA5NTA (JO39EQ)\r", "FF\r")) {
            assertEquals(want, rd.line())
        }
        srv.write("FQ\r")
        done.await()
        Unit
    }

    @Test fun sessionCMSWithMessageDeferred() = runBlocking {
        val (client, srv) = PipeStream.pair()
        val s = B2FSession("LA5NTA", "LA1B-10", "JO39EQ", null)
        val done = async { runCatching { s.exchange(client) } }
        srv.write("[WL2K-2.8.4.8-B2FWIHJM$]\rTest CMS >\r")
        val rd = LineReader(srv)
        repeat(4) { rd.line() }
        srv.write("FC EM TJKYEIMMHSRB 527 123 0\rF> 3b\r")
        assertEquals("FS =\r", rd.line())
        // The CMS sends FQ and hangs up instead of waiting for our turn.
        srv.write("FQ\r")
        srv.close()
        val r = done.await()
        // Also fine: we may still have been writing FF when the CMS hung up.
        r.exceptionOrNull()?.let { assertTrue("$it", it is B2FException.ConnectionLost) }
        Unit
    }

    @Test fun sessionCMSv4() = runBlocking {
        val (client, srv) = PipeStream.pair()
        val s = B2FSession("LA5NTA", "LA1B-10", "JO39EQ", null)
        val done = async { s.exchange(client) }
        srv.write("[WL2K-4.0-B2FWIHJM$]\rTest CMS >\r")
        val rd = LineReader(srv)
        repeat(4) { rd.line() }
        srv.write(";PM: LA5NTA TJKYEIMMHSRB 123 martin.h.pedersen@gmail.com\r;WARNING: Foo bar baz\r")
        srv.write("FC EM TJKYEIMMHSRB 527 123 0\rF> 3b\r")
        assertEquals("FS =\r", rd.line())
        assertEquals("FF\r", rd.line())
        srv.write(";WARNING: Foo bar baz\rFQ\r")
        done.await()
        Unit
    }

    @Test fun secureLoginHandshake() = runBlocking {
        val (client, srv) = PipeStream.pair()
        val s = B2FSession("LA5NTA", "WL2K", "JO39EQ", null)
        s.password = { if (it.addr == "LA5NTA") "FOOBAR" else null }
        val done = async { s.exchange(client) }
        srv.write("[WL2K-5.0-B2FWIHJM$]\r;PQ: 23753528\rCMS via LA1B >\r")
        val rd = LineReader(srv)
        val lines = (0 until 5).map { rd.line() }
        assertEquals(";PR: 72768415\r", lines[2])
        srv.write("FQ\r")
        done.await()
        Unit
    }

    @Test fun secureLoginWithoutPasswordFails() = runBlocking {
        val (client, srv) = PipeStream.pair()
        val s = B2FSession("LA5NTA", "WL2K", "JO39EQ", null)
        val done = async { runCatching { s.exchange(client) } }
        srv.write("[WL2K-5.0-B2FWIHJM$]\r;PQ: 23753528\rCMS >\r")
        val e = done.await().exceptionOrNull()
        assertTrue("$e", e is B2FException.PasswordRequired)
    }

    @Test fun remoteErrorLine() = runBlocking {
        val (client, srv) = PipeStream.pair()
        val s = B2FSession("LA5NTA", "WL2K", "JO39EQ", MemoryMailbox(listOf(makeMessage(from = "LA5NTA", to = "N0CALL"))))
        s.password = { "WRONG" }
        val done = async { runCatching { s.exchange(client) } }
        srv.write("[WL2K-5.0-B2FWIHJM$]\r;PQ: 23753528\rCMS >\r")
        srv.write("*** [1] Secure login failed - account password does not match. - Disconnecting\r")
        val e = done.await().exceptionOrNull()
        assertTrue("$e", e is B2FException && e.isLoginFailure)
    }

    /** A gateway that sends one message and accepts one, checked byte by byte against what a CMS sends. */
    @Test fun scriptedGatewayExchange() = runBlocking {
        val (client, srv) = PipeStream.pair()
        val outMsg = makeMessage(from = "N0CALL", to = "someone@example.com", subject = "Out", body = "Going out\nover the air")
        val box = MemoryMailbox(listOf(outMsg))
        val s = B2FSession("N0CALL", "LA1B-10", "JO39EQ", box)
        val done = async { s.exchange(client) }

        srv.write("[WL2K-5.0-B2FWIHJM$]\rTest CMS >\r")
        val rd = StreamReader(srv)
        suspend fun line() = rd.readUntil(13).let { String(it, 0, it.size - 1) }
        repeat(3) { line() }

        // Our proposal block.
        val prop = line()
        assertTrue(prop, prop.startsWith("FC EM ${outMsg.mid} "))
        assertEquals(String.format("F> %02X", (-sum("$prop\r")) and 0xff), line())
        srv.write("FS +\r")

        // The compressed message.
        assertEquals(1, rd.readByte())
        val hlen = rd.readByte()
        val title = rd.readUntil(0)
        val off = rd.readUntil(0)
        assertEquals(title.size + off.size, hlen)
        assertEquals("Out", String(title, 0, title.size - 1))
        val data = java.io.ByteArrayOutputStream()
        var csum = 0
        while (true) {
            val b = rd.readByte()
            if (b == 4) {
                csum += rd.readByte()
                break
            }
            assertEquals(2, b)
            val chunk = rd.read(rd.readByte())
            csum += chunk.sumOf { it.u }
            data.write(chunk)
        }
        assertEquals(0, csum and 0xff)
        val got = Message.parse(LZHUF.decompress(data.toByteArray()))
        assertEquals(outMsg.mid, got.mid)
        assertEquals("Going out\r\nover the air\r\n", got.bodyText)

        // Our turn ends; the gateway proposes one message for us.
        val inMsg = makeMessage(from = "SERVICE", to = "N0CALL", subject = "Welcome ÆØÅ", body = "Inbound body")
        inMsg.addFile(Attachment("a.txt", "attached".toByteArray()))
        val p = Proposal.of(inMsg)
        srv.write(p.line + "\r" + String.format("F> %02X\r", (-sum(p.line + "\r")) and 0xff))
        assertEquals("FS +", line())
        val w = "Welcome".toByteArray()
        val blk = java.io.ByteArrayOutputStream()
        blk.write(byteArrayOf(1, (w.size + 3).toByte()) + w + bytes(0, 0x30, 0))
        blk.write(byteArrayOf(2, p.compressedData.size.toByte()) + p.compressedData)
        blk.write(byteArrayOf(4, ((-p.compressedData.sumOf { it.u }) and 0xff).toByte()))
        srv.write(blk.toByteArray())
        assertEquals("FF", line())
        srv.write("FQ\r")
        val stats = done.await()

        assertEquals(listOf(outMsg.mid), stats.sent)
        assertEquals(listOf(inMsg.mid), stats.received)
        assertEquals("Welcome ÆØÅ", box.inbox.first().subject)
        assertArrayEquals("attached".toByteArray(), box.inbox.first().files.first().data)
        assertEquals(listOf(outMsg.mid), box.sent.map { it.first })
    }

    /** Two of our own sessions, one as master, swap messages both ways (P2P). */
    @Test fun p2pBothWays() = runBlocking {
        val (a, b) = PipeStream.pair()
        val boxA = MemoryMailbox(listOf(makeMessage(from = "LA5NTA", to = "N0CALL", subject = "A to B", body = "abc ".repeat(500))))
        val boxB = MemoryMailbox(listOf(makeMessage(from = "N0CALL", to = "LA5NTA", subject = "B to A", body = "short")))
        val sa = B2FSession("LA5NTA", "N0CALL", "JO39EQ", boxA)
        val sb = B2FSession("N0CALL", "LA5NTA", "JO39EQ", boxB)
        sb.isMaster = true
        val ra = async { sa.exchange(a) }
        val rb = async { sb.exchange(b) }
        assertEquals(1, ra.await().sent.size)
        assertEquals(1, rb.await().sent.size)
        assertEquals(listOf("B to A"), boxA.inbox.map { it.subject })
        assertEquals(listOf("A to B"), boxB.inbox.map { it.subject })
        // 2000 bytes wrap into 998 + 998 + 4 byte lines.
        assertEquals(2000 + 3 * 2, boxB.inbox.first().body.size)
    }
}

fun assertThrows(f: () -> Unit) {
    try {
        f()
    } catch (_: Exception) {
        return
    }
    fail("expected an error")
}

class MessageTest {
    @Test fun roundTripWithWhitespaceBeforeHeader() {
        val m1 = Message("LA5NTA")
        m1.addTo("N0CALL")
        m1.setBody("Hello world")
        val m2 = Message.parse("\r\n\r\n\t ".toByteArray() + m1.bytes())
        assertEquals(m1.header, m2.header)
        assertEquals("Hello world\r\n", m2.bodyText)
    }

    @Test fun emptyMessageErrors() {
        assertThrows { Message.parse(ByteArray(0)) }
        assertThrows { Message.parse("\r\n\r\nfoobar".toByteArray()) }
    }

    @Test fun wireFormat() {
        val m = Message()
        m.setField("Mid", "ABCDEFGHIJKL")
        m.setField("Date", "2016/12/30 01:00")
        m.setField("From", "LA5NTA")
        m.setField("Mbo", "LA5NTA")
        m.setField("Type", "Private")
        m.addTo("N0CALL", "foo@bar.baz")
        m.subject = "Test"
        m.setBody("Line 1\nLine 2")
        assertEquals(
            "Mid: ABCDEFGHIJKL\r\nBody: 16\r\nContent-Transfer-Encoding: 8bit\r\n" +
                "Content-Type: text/plain; charset=ISO-8859-1\r\nDate: 2016/12/30 01:00\r\nFrom: LA5NTA\r\n" +
                "Mbo: LA5NTA\r\nSubject: Test\r\nTo: N0CALL\r\nTo: SMTP:foo@bar.baz\r\nType: Private\r\n\r\n" +
                "Line 1\r\nLine 2\r\n",
            String(m.bytes()),
        )
    }

    @Test fun parseDate() {
        val want = Instant.ofEpochSecond(1_483_059_600) // 2016-12-30 01:00 UTC
        for (s in listOf(
            "2016/12/30 01:00", "2016.12.30 01:00", "2016-12-30 01:00", "20161230010000",
            "Fri, 30 Dec 2016 01:00:00 -0000", "Fri, 30 Dec 2016 01:00:00 GMT",
        )) {
            assertEquals(s, want, Message.parseDate(s))
        }
    }

    @Test fun addressFromString() {
        assertEquals(Address(addr = "LA5NTA"), Address.parse("LA5NTA"))
        assertEquals(Address(addr = "LA5NTA"), Address.parse("la5nta"))
        assertEquals(Address(addr = "LA5NTA"), Address.parse("LA5NTA@winlink.org"))
        assertEquals(Address(addr = "LA5NTA"), Address.parse("la5nta@WINLINK.org"))
        assertEquals(Address("SMTP", "foo@bar.baz"), Address.parse("foo@bar.baz"))
        assertEquals("SMTP:foo@bar.baz", Address.parse("foo@bar.baz").toString())
    }

    @Test fun encodedWords() {
        val enc = MIMEWords.encode("æøå.txt")
        assertTrue(enc, enc.all { it.code < 128 })
        assertEquals("æøå.txt", MIMEWords.decode(enc))
        assertEquals("æøå.txt", MIMEWords.decode("=?utf-8?q?=C3=A6=C3=B8=C3=A5.txt?="))
        assertEquals("æøå", MIMEWords.decode("=?UTF-8?B?w6bDuMOl?="))
        assertEquals("ab", MIMEWords.decode("=?ISO-8859-1?q?a?= =?ISO-8859-1?q?b?="))
        assertEquals("plain subject", MIMEWords.encode("plain subject"))
        val long = "ø".repeat(100) + " 📡"
        assertEquals(long, MIMEWords.decode(MIMEWords.encode(long)))
    }

    @Test fun decodeLatin1FileName() {
        val m = Message("N0CALL")
        m.addTo("LA5NTA")
        m.setBody("x")
        m.addFile(Attachment("æøå.txt", ByteArray(0)))
        for (header in listOf(m.values("File")[0], "0 æøå.txt")) {
            val copy = m.copy()
            copy.removeField("File")
            copy.addField("File", header)
            assertEquals("æøå.txt", Message.parse(copy.bytes()).files.first().name)
        }
        // Raw ISO-8859-1 bytes in the header.
        val raw = String(m.bytes(), Charsets.ISO_8859_1)
        val replaced = raw.replace(m.values("File")[0], "0 æøå.txt").toByteArray(Charsets.ISO_8859_1)
        assertEquals("æøå.txt", Message.parse(replaced).files.first().name)
    }

    @Test fun utf8BodyWhenLatin1CannotHoldIt() {
        val m = makeMessage(body = "73 de 📡")
        assertEquals("UTF-8", m.charset)
        assertEquals("73 de 📡\r\n", Message.parse(m.bytes()).bodyText)
    }

    @Test fun validation() {
        val m = Message("N0CALL")
        assertThrows { m.validate() }
        m.addTo("LA5NTA")
        m.subject = "s"
        m.setBody("b")
        m.validate()
        assertEquals(12, m.mid.length)
        assertNotNull(m.date)
    }
}
