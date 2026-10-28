// Telnet login to the Winlink CMS, the internet transport.
//
// Follows wl2k-go's transport/telnet (MIT): answer the "Callsign :" and
// "Password :" prompts, after which the CMS starts a B2F session.

package com.nr5p.winlink

object CMSTelnet {
    const val HOST = "server.winlink.org"
    const val PORT = 8772
    /** The fixed telnet password; the account password is checked by the B2F secure login. */
    const val PASSWORD = "CMSTelnet"
    const val TARGET_CALL = "WL2K"

    /** Connects and logs in, returning a stream positioned at the start of the B2F handshake. */
    suspend fun connect(mycall: String, host: String = HOST, port: Int = PORT, log: (String) -> Unit = {}): ByteStream {
        val tcp = TCPStream.connect(host, port, 30.0)
        try {
            val rest = login(tcp, mycall, log)
            return PrefixedStream(tcp, rest)
        } catch (e: Throwable) {
            tcp.close()
            throw e
        }
    }

    /** Answers the prompts on [stream] and returns any bytes read past the password prompt. */
    internal suspend fun login(stream: ByteStream, mycall: String, log: (String) -> Unit): ByteArray {
        var buf = ByteArray(0)
        var sentCall = false
        while (true) {
            val chunk = stream.read()
            if (chunk.isEmpty()) throw StreamException.Closed()
            buf += chunk
            // Prompts may arrive without a line ending, so look at whatever we have.
            while (true) {
                if (!sentCall) {
                    val at = find("callsign", buf)
                    if (at != null) {
                        val end = lineEnd(buf, at)
                        log(String(buf, 0, end).trim())
                        buf = buf.copyOfRange(end, buf.size)
                        stream.write("${mycall.uppercase()}\r")
                        sentCall = true
                        continue
                    }
                }
                val at = find("password", buf)
                if (at != null) {
                    val end = lineEnd(buf, at)
                    log(String(buf, 0, end).trim())
                    buf = buf.copyOfRange(end, buf.size)
                    stream.write("$PASSWORD\r")
                    return buf
                }
                break
            }
        }
    }

    /** The index just past a case-insensitive ASCII match of [needle]. */
    private fun find(needle: String, b: ByteArray): Int? {
        val n = needle.toByteArray()
        if (b.size < n.size) return null
        for (i in 0..(b.size - n.size)) {
            var ok = true
            for (j in n.indices) {
                if ((b[i + j].u or 0x20) != n[j].u) {
                    ok = false
                    break
                }
            }
            if (ok) return i + n.size
        }
        return null
    }

    /** The index just past the prompt: through a CR/LF if one follows, else to the end of what we have. */
    private fun lineEnd(b: ByteArray, from: Int): Int {
        var i = minOf(from, b.size)
        while (i < b.size && b[i] != 13.toByte() && b[i] != 10.toByte()) i += 1
        while (i < b.size && (b[i] == 13.toByte() || b[i] == 10.toByte())) i += 1
        return i
    }
}
