// A B2F (FBB B2 forwarding protocol with Winlink extensions) exchange.
//
// Ported from la5nta/wl2k-go's fbb package (MIT, Martin Hebnes Pedersen).
// Only B2 ("FC") proposals with LZHUF compression are supported, which is
// what the Winlink CMS, RMS gateways and Winlink Express use.

package com.nr5p.winlink

/** A protocol error; the subclasses are the other ways an exchange fails. */
open class B2FException(message: String) : Exception(message) {
    class Remote(val text: String) : B2FException("remote: $text")
    class NoB2Support : B2FException("Remote does not support B2 Forwarding Protocol")
    class PasswordRequired : B2FException("The gateway asked for a secure login but no Winlink password is set")
    class ConnectionLost : B2FException("connection lost")

    /** True when the CMS rejected the secure login password. */
    val isLoginFailure: Boolean get() = this is Remote && text.lowercase().contains("secure login failed")
}

/** Where a session gets outbound messages and puts inbound ones. */
interface Mailbox {
    /** Messages ready to send to the connected node. [forwarders] is empty when talking to the CMS/RMS. */
    fun outbound(forwarders: List<Address>): List<Message>
    fun markSent(mid: String, rejected: Boolean)
    fun markDeferred(mid: String)
    /** Accept unless the MID was already received. */
    fun answer(proposal: Proposal): ProposalAnswer
    fun receive(message: Message)
}

data class PendingMessage(val mid: String, val to: Address, val from: Address, val subject: String, val size: Int) {
    companion object {
        /** Parses ";PM: TO MID SIZE FROM SUBJECT". */
        fun parse(line: String): PendingMessage? {
            val s = line.removePrefix(";PM: ")
            val parts = s.split(" ", limit = 5)
            if (parts.size != 5) return null
            return PendingMessage(parts[1], Address.parse(parts[0]), Address.parse(parts[3]), parts[4], parts[2].toIntOrNull() ?: 0)
        }
    }
}

data class TrafficStats(val received: MutableList<String> = mutableListOf(), val sent: MutableList<String> = mutableListOf())

sealed class SessionEvent {
    /** A protocol line, with the direction (">" sent, "<" received). */
    data class Line(val text: String, val outbound: Boolean) : SessionEvent()
    data class Info(val text: String) : SessionEvent()
    data class Progress(val mid: String, val title: String, val sending: Boolean, val done: Int, val total: Int) : SessionEvent()
}

class B2FSession(
    mycall: String,
    targetcall: String,
    val locator: String,
    private val mailbox: Mailbox?,
    auxiliaryAddresses: List<Address> = emptyList(),
) {
    data class UserAgent(val name: String, val version: String)

    val mycall = mycall.uppercase()
    val targetcall = targetcall.uppercase()
    var isMaster = false
    var motd: List<String> = emptyList()
    /** Send ";FW:" in the handshake. A CMS-like master leaves it out, which tells the
     *  client it may hand over mail for anyone. */
    var announceForwarders = true
    var userAgent = UserAgent("Gateway", "1.0")
    /** The Winlink password for an address (the first is mycall). Null means none known. */
    var password: (Address) -> String? = { null }
    var onEvent: (SessionEvent) -> Unit = {}

    var remoteSID = ""; private set
    var remoteForwarders: List<Address> = emptyList(); private set
    val pendingMessages = linkedMapOf<String, PendingMessage>()
    val stats = TrafficStats()

    private val localForwarders = listOf(Address.parse(mycall)) + auxiliaryAddresses
    private var quitReceived = false
    private var quitSent = false
    private var remoteNoMsgs = false
    private lateinit var rd: StreamReader
    private lateinit var conn: ByteStream

    companion object {
        const val LOCAL_SID = "B2FHM$"
        /** Paclink-unix uses 250; 125 keeps AX.25 paclen 128 links happy. */
        const val MAX_BLOCK_LENGTH = 125
        const val MAX_PROPOSALS = 5

        internal fun clean(s: String): String = s.trim().trim('\u0000')

        /** "*** some error" → "some error". */
        internal fun errorLine(s: String): String? {
            if (!s.startsWith("*")) return null
            val rest = s.substring(s.lastIndexOf('*') + 1).trim()
            return rest.ifEmpty { null }
        }

        internal fun parseFW(line: String): List<Address> {
            if (!line.startsWith(";FW: ")) throw B2FException("Malformed forward line")
            return line.substring(5).split(" ").filter { it.isNotEmpty() }.map { Address.parse(it.split("|", limit = 2)[0]) }
        }

        internal fun decodeText(b: ByteArray): String = Message.decodeUTF8Strict(b) ?: String(b, Charsets.ISO_8859_1)
    }

    val done: Boolean get() = quitReceived || quitSent

    /** Runs the whole exchange over [stream] and closes it. */
    suspend fun exchange(stream: ByteStream, prefix: ByteArray = ByteArray(0)): TrafficStats {
        conn = stream
        rd = StreamReader(stream, prefix)
        try {
            handshake()
            var myTurn = !isMaster
            while (!done) {
                if (myTurn) quitSent = handleOutbound() else quitReceived = handleInbound()
                myTurn = !myTurn
            }
            // Give the last FQ time to leave before hanging up.
            runCatching { stream.flush() }
            stream.close()
            return stats
        } catch (e: StreamException.Closed) {
            stream.close()
            throw B2FException.ConnectionLost()
        } catch (e: B2FException.ConnectionLost) {
            stream.close()
            throw e
        } catch (e: B2FException.Remote) {
            stream.close()
            throw e
        } catch (e: kotlinx.coroutines.CancellationException) {
            stream.close()
            throw e
        } catch (e: Exception) {
            // Probably a protocol error: tell the remote, then hang up.
            runCatching {
                stream.write("*** ${e.message}\r\n")
                stream.flush()
            }
            stream.close()
            throw e
        }
    }

    // Lines

    private suspend fun send(line: String) {
        onEvent(SessionEvent.Line(line, true))
        conn.write("$line\r")
    }

    private suspend fun nextLine(parseErrors: Boolean = true): String {
        val raw = rd.readUntil(13)
        val line = clean(decodeText(raw))
        onEvent(SessionEvent.Line(line, false))
        if (parseErrors) errorLine(line)?.let { throw B2FException.Remote(it) }
        return line
    }

    // Handshake

    private suspend fun handshake() {
        if (isMaster) {
            for (l in motd) conn.write("$l\r")
            sendHandshake(null)
        }
        var sid = ""
        var challenge: String? = null
        while (true) {
            val b = rd.peek()
            if (b == 'F'.code && isMaster) break
            // The CMS sends lines such as "*** MTD Stats ..." here that are not errors.
            val line = nextLine(parseErrors = false)
            if (line.startsWith("[") && line.endsWith("]")) {
                val dash = line.lastIndexOf('-')
                if (dash < 0) throw B2FException("Bad SID line: $line")
                sid = line.substring(dash + 1, line.length - 1).uppercase()
                if (!sid.contains("B2")) throw B2FException.NoB2Support()
            } else if (line.startsWith(";FW")) {
                remoteForwarders = parseFW(line)
            } else if (line.startsWith(";PQ")) {
                challenge = line.drop(5)
            } else if (line.endsWith(">")) {
                break
            }
        }
        if (sid.isEmpty()) throw B2FException("No sid in handshake")
        remoteSID = sid
        if (!isMaster) sendHandshake(challenge)
    }

    private suspend fun sendHandshake(challenge: String?) {
        val out = StringBuilder(";FW:")
        localForwarders.forEachIndexed { i, addr ->
            val pw = if (challenge != null && i > 0) password(addr) else null
            if (challenge != null && !pw.isNullOrEmpty()) {
                // Winlink Express separates the aux address password hash with a pipe.
                out.append(" ${addr.addr}|${SecureLogin.response(challenge, pw)}")
            } else {
                out.append(" ${addr.addr}")
            }
        }
        val lines = if (announceForwarders) mutableListOf(out.toString()) else mutableListOf()
        lines += "[${userAgent.name}-${userAgent.version}-$LOCAL_SID]"
        if (challenge != null) {
            val pw = password(localForwarders[0])
            if (pw.isNullOrEmpty()) throw B2FException.PasswordRequired()
            lines += ";PR: ${SecureLogin.response(challenge, pw)}"
        }
        lines += "; $targetcall DE $mycall ($locator)" + if (isMaster) ">" else ""
        for (l in lines) onEvent(SessionEvent.Line(l, true))
        conn.write(lines.joinToString("") { "$it\r" })
    }

    // Outbound

    private fun outboundProposals(): List<Proposal> {
        val mb = mailbox ?: return emptyList()
        val props = mutableListOf<Proposal>()
        for (m in mb.outbound(remoteForwarders)) {
            try {
                props += Proposal.of(m)
            } catch (e: Exception) {
                onEvent(SessionEvent.Info("Ignoring invalid outbound message ${m.mid}: ${e.message}"))
            }
        }
        return Proposal.sorted(props)
    }

    private suspend fun handleOutbound(): Boolean {
        val outbound = outboundProposals()
        if (outbound.isEmpty()) {
            send(if (remoteNoMsgs) "FQ" else "FF")
            return remoteNoMsgs
        }
        val sent = sendOutbound(outbound.take(MAX_PROPOSALS))
        for ((mid, rejected) in sent.entries.toList()) {
            if (rejected) {
                mailbox?.markSent(mid, true)
                sent.remove(mid)
            }
        }
        // After a turnover only 'F' or ';' are valid; anything else (usually "***") is an error.
        val b = rd.peek()
        if (b != 'F'.code && b != ';'.code) {
            val line = nextLine()
            throw B2FException("Unexpected response: '$line'")
        }
        for ((mid, rejected) in sent) {
            mailbox?.markSent(mid, rejected)
            stats.sent += mid
        }
        return false
    }

    private suspend fun sendOutbound(props: List<Proposal>): MutableMap<String, Boolean> {
        var checksum = 0
        val lines = mutableListOf<String>()
        for (p in props) {
            lines += p.line
            for (c in p.line.toByteArray()) checksum += c.u
            checksum += 13
        }
        lines += String.format("F> %02X", (-checksum) and 0xff)
        for (l in lines) onEvent(SessionEvent.Line(l, true))
        conn.write(lines.joinToString("") { "$it\r" })

        var reply = ""
        while (reply.isEmpty()) {
            val line = nextLine()
            if (line.startsWith("FS ")) {
                reply = line
            } else if (line.startsWith(";PM")) {
                PendingMessage.parse(line)?.let { pendingMessages[it.mid] = it }
            } else if (line.startsWith(";")) {
                continue
            } else {
                throw B2FException("Expected proposal answer from remote. Got: $line")
            }
        }
        Proposal.applyAnswer(reply, props)

        val sent = linkedMapOf<String, Boolean>()
        for (p in props) {
            when (p.answer) {
                ProposalAnswer.DEFER, null -> mailbox?.markDeferred(p.mid)
                ProposalAnswer.REJECT -> sent[p.mid] = true
                ProposalAnswer.ACCEPT -> {
                    writeCompressed(p)
                    sent[p.mid] = false
                }
            }
        }
        return sent
    }

    private suspend fun writeCompressed(p: Proposal) {
        onEvent(SessionEvent.Info("Transmitting [${p.title}] [offset ${p.offset}]"))
        if (p.compressedSize < 6) throw B2FException("Invalid compressed data")
        // The title must be ASCII and the header length must fit a byte.
        var title = MIMEWords.encode(p.title.take(80))
        if (title.toByteArray().size > 200) title = title.take(200)
        val offset = p.offset.toString()
        val titleBytes = title.toByteArray()
        val offsetBytes = offset.toByteArray()
        val header = byteArrayOf(1, (titleBytes.size + offsetBytes.size + 2).toByte()) + titleBytes + 0.toByte() + offsetBytes + 0.toByte()

        val data = p.compressedData
        val start = p.offset
        var checksum = 0
        var i = start
        var first = true
        while (i < data.size) {
            val n = minOf(MAX_BLOCK_LENGTH, data.size - i)
            val out = java.io.ByteArrayOutputStream()
            if (first) out.write(header)
            first = false
            out.write(2)
            out.write(n)
            for (k in i until i + n) checksum += data[k].u
            out.write(data, i, n)
            conn.write(out.toByteArray())
            i += n
            onEvent(SessionEvent.Progress(p.mid, p.title, true, i - start, data.size - start))
        }
        conn.write(byteArrayOf(4, ((-checksum) and 0xff).toByte()))
        // Block until it has gone over the air.
        conn.flush()
    }

    // Inbound

    private suspend fun handleInbound(): Boolean {
        var checksum = 0
        val proposals = mutableListOf<Proposal>()
        var quit = false
        loop@ while (true) {
            val line = nextLine()
            if (line.startsWith(";PM")) {
                PendingMessage.parse(line)?.let { pendingMessages[it.mid] = it }
                continue
            }
            if (line.isEmpty() || line.startsWith(";")) continue
            if (line.length < 2 || !line.startsWith("F")) throw B2FException("Got unexpected protocol line: '$line'")
            when (line.take(2)) {
                "FA", "FB", "FC", "FD" -> {
                    for (c in line.toByteArray()) checksum += c.u
                    checksum += 13
                    proposals += Proposal.parse(line)
                }
                "FF" -> {
                    remoteNoMsgs = true
                    break@loop
                }
                "FQ" -> {
                    quit = true
                    break@loop
                }
                "F>" -> {
                    val theirs = line.drop(3).trim().toIntOrNull(16) ?: -1
                    val ours = (-checksum) and 0xff
                    if (theirs != ours) throw B2FException("Checksum error ($ours-$theirs)")
                    if (proposals.isEmpty()) {
                        remoteNoMsgs = true
                        return false
                    }
                    remoteNoMsgs = false
                    onEvent(SessionEvent.Info("${proposals.size} proposal(s) received"))
                    answerProposals(proposals)
                    break@loop
                }
                else -> throw B2FException("Unknown protocol command ${line.drop(1).take(1)}")
            }
        }

        val accepted = proposals.filter { it.answer == ProposalAnswer.ACCEPT }
        if (quit && accepted.isNotEmpty()) throw B2FException("Got quit command when inbound proposals were pending")
        for (p in accepted) {
            readCompressed(p)
            val msg = p.message()
            mailbox?.receive(msg)
            stats.received += p.mid
        }
        return quit
    }

    private suspend fun answerProposals(proposals: List<Proposal>) {
        val seen = mutableSetOf<String>()
        for (p in proposals) {
            p.answer = when {
                // Radio-only gateways sometimes propose the same MID twice in a block.
                p.mid in seen -> ProposalAnswer.DEFER
                p.code != 'C' -> {
                    onEvent(SessionEvent.Info("Deferring ${p.mid} (unsupported format)"))
                    ProposalAnswer.DEFER
                }
                mailbox != null -> mailbox.answer(p)
                else -> ProposalAnswer.DEFER
            }
            seen += p.mid
        }
        send("FS " + proposals.joinToString("") { it.answer!!.code.toString() })
    }

    private suspend fun readCompressed(p: Proposal) {
        when (val first = rd.readByte()) {
            1 -> {}
            '*'.code -> {
                val line = nextLine(parseErrors = false)
                throw B2FException.Remote("Got error from CMS: $line")
            }
            else -> throw B2FException("First byte not as expected, got $first")
        }
        val headerLength = rd.readByte()
        val rawTitle = rd.readUntil(0).let { it.copyOf(it.size - 1) }
        p.title = MIMEWords.decode(decodeText(rawTitle))
        val offsetBytes = rd.readUntil(0).let { it.copyOf(it.size - 1) }
        if (headerLength != rawTitle.size + offsetBytes.size + 2) {
            throw B2FException("Header length mismatch: expected $headerLength, got ${rawTitle.size + offsetBytes.size + 2}")
        }
        val offset = String(offsetBytes).toIntOrNull() ?: throw B2FException("Offset header not parseable as integer")
        if (offset != p.offset) throw B2FException("Expected offset ${p.offset}, got $offset")
        onEvent(SessionEvent.Info("Receiving [${p.title}] [offset ${p.offset}]"))

        val buf = java.io.ByteArrayOutputStream()
        var checksum = 0
        while (true) {
            when (val c = rd.readByte()) {
                2 -> {
                    var length = rd.readByte()
                    if (length == 0) length = 256
                    val chunk = rd.read(length)
                    for (b in chunk) checksum = (checksum + b.u) % 256
                    buf.write(chunk)
                    onEvent(SessionEvent.Progress(p.mid, p.title, false, buf.size(), p.compressedSize))
                }
                4 -> {
                    checksum = (checksum + rd.readByte()) % 256
                    if (checksum != 0) throw B2FException("Bad checksum")
                    if (buf.size() != p.compressedSize) throw B2FException("Length mismatch after EOT")
                    p.compressedData = buf.toByteArray()
                    return
                }
                else -> throw B2FException("Unexpected byte in compressed stream: $c")
            }
        }
    }
}
