// The Winlink message structure (winlink.org/B2F): a MIME-like header block,
// a body, and attachments, each section followed by CRLF.
//
// Ported from la5nta/wl2k-go's fbb package (MIT, Martin Hebnes Pedersen).

package com.nr5p.winlink

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.UUID

data class Address(val proto: String = "", val addr: String) {
    override fun toString(): String = if (proto.isEmpty()) addr else "$proto:$addr"

    companion object {
        /** Parses N0CALL, N0CALL@winlink.org, foo@bar.baz (SMTP) or PROTO:addr. */
        fun parse(s: String): Address {
            val colon = s.split(":")
            val at = s.split("@")
            val a = when {
                colon.size == 2 -> Address(colon[0], colon[1])
                at.size == 1 -> Address(addr = s)
                at[1].lowercase() == "winlink.org" -> Address(addr = at[0])
                else -> Address("SMTP", s)
            }
            return if (a.proto.isEmpty()) a.copy(addr = a.addr.uppercase()) else a
        }
    }
}

class MessageException(message: String) : Exception(message) {
    companion object {
        fun invalid(field: String, reason: String) = MessageException("$field: $reason")
        fun malformed(s: String) = MessageException("malformed message: $s")
    }
}

class Attachment(val name: String, val data: ByteArray) {
    override fun equals(other: Any?) = other is Attachment && other.name == name && other.data.contentEquals(data)
    override fun hashCode() = name.hashCode() * 31 + data.contentHashCode()
}

class Message() {
    /** Canonical header key → values, in insertion order per key. */
    private val _header = LinkedHashMap<String, MutableList<String>>()
    val header: Map<String, List<String>> get() = _header
    var body: ByteArray = ByteArray(0)
    val files = mutableListOf<Attachment>()

    /** A new private message from [mycall] with a fresh MID and the current date. */
    constructor(from: String, type: String = "Private", date: Instant = Instant.now()) : this() {
        setField("Mid", generateMID(from))
        this.date = date
        setField("From", Address.parse(from).toString())
        setField("Mbo", from)
        setField("Type", type)
    }

    fun copy(): Message {
        val m = Message()
        for ((k, v) in _header) m._header[k] = v.toMutableList()
        m.body = body
        m.files += files
        return m
    }

    override fun equals(other: Any?) =
        other is Message && other._header == _header && other.body.contentEquals(body) && other.files == files

    override fun hashCode() = _header.hashCode()

    // Header access

    fun field(key: String): String = _header[canonicalKey(key)]?.firstOrNull() ?: ""
    fun values(key: String): List<String> = _header[canonicalKey(key)] ?: emptyList()
    fun setField(key: String, value: String) { _header[canonicalKey(key)] = mutableListOf(value) }
    fun addField(key: String, value: String) { _header.getOrPut(canonicalKey(key)) { mutableListOf() }.add(value) }
    fun removeField(key: String) { _header.remove(canonicalKey(key)) }

    val mid: String get() = field("Mid")
    val from: Address get() = Address.parse(field("From"))
    val to: List<Address> get() = values("To").map(Address::parse)
    val cc: List<Address> get() = values("Cc").map(Address::parse)
    val receivers: List<Address> get() = to + cc
    val type: String get() = field("Type")

    var subject: String
        get() = MIMEWords.decode(field("Subject"))
        set(v) = setField("Subject", MIMEWords.encode(v))

    var date: Instant?
        get() = parseDate(field("Date"))
        set(v) { if (v != null) setField("Date", formatDate(v)) }

    fun addTo(vararg addrs: String) { for (a in addrs) addField("To", Address.parse(a).toString()) }
    fun addCc(vararg addrs: String) { for (a in addrs) addField("Cc", Address.parse(a).toString()) }
    fun addTo(addrs: List<String>) { for (a in addrs) addField("To", Address.parse(a).toString()) }
    fun addCc(addrs: List<String>) { for (a in addrs) addField("Cc", Address.parse(a).toString()) }

    // Body

    /** Sets the body: CRLF line endings, lines wrapped at 998 bytes, ISO-8859-1 when it fits, else UTF-8. */
    fun setBody(text: String) {
        val charset = if (canBeLatin1(text)) DEFAULT_CHARSET else "UTF-8"
        setField("Content-Transfer-Encoding", "8bit")
        setField("Content-Type", "text/plain; charset=$charset")
        val lines = text.replace("\r\n", "\n").split("\n").toMutableList()
        if (lines.last() == "") lines.removeAt(lines.size - 1)
        val out = java.io.ByteArrayOutputStream()
        for (line in lines) {
            var bytes = encode(line, charset)
            do {
                val n = minOf(bytes.size, 998)
                out.write(bytes, 0, n)
                out.write(13); out.write(10)
                bytes = bytes.copyOfRange(n, bytes.size)
            } while (bytes.isNotEmpty())
        }
        body = out.toByteArray()
        setField("Body", body.size.toString())
    }

    val bodySize: Int get() = field("Body").toIntOrNull() ?: 0

    val charset: String
        get() {
            val ct = field("Content-Type")
            for (part in ct.split(";").drop(1)) {
                val kv = part.split("=", limit = 2)
                if (kv.size == 2 && kv[0].trim().lowercase() == "charset") {
                    return kv[1].trim(' ', '"')
                }
            }
            return DEFAULT_CHARSET
        }

    val bodyText: String get() = decode(body, charset)

    fun addFile(file: Attachment) {
        files += file
        addField("File", "${file.data.size} ${MIMEWords.encode(file.name)}")
    }

    // Validation & serialisation

    fun validate() {
        if (mid.isEmpty()) throw MessageException.invalid("MID", "Empty MID")
        if (mid.length > 12) throw MessageException.invalid("MID", "MID too long")
        if (receivers.isEmpty()) throw MessageException.invalid("To/Cc", "No recipient")
        if (field("From").isEmpty()) throw MessageException.invalid("From", "Empty From field")
        if (bodySize == 0) throw MessageException.invalid("Body", "Empty body")
        if (field("Subject").isEmpty()) throw MessageException.invalid("Subject", "Empty subject")
        if (field("Subject").length > 128) throw MessageException.invalid("Subject", "Subject too long")
        for (f in files) {
            if (f.name.toByteArray().size > 255) throw MessageException.invalid("Files", "Attachment file name too long: ${f.name}")
        }
    }

    /** The message in Winlink wire format: Mid first, then the other header keys sorted. */
    fun bytes(): ByteArray {
        if (parseDate(field("Date")) == null && field("Date").isNotEmpty()) throw MessageException.malformed("bad Date header")
        if (mid.isEmpty()) throw MessageException.malformed("missing MID in header")
        val s = StringBuilder("Mid: $mid\r\n")
        for (key in _header.keys.filter { it != "Mid" }.sorted()) {
            for (v in _header[key]!!) s.append("$key: ${v.trim()}\r\n")
        }
        s.append("\r\n")
        // Header values are ASCII (encoded words), so UTF-8 is exact.
        val out = java.io.ByteArrayOutputStream()
        out.write(s.toString().toByteArray(Charsets.UTF_8))
        out.write(body)
        if (files.isNotEmpty()) { out.write(13); out.write(10) }
        for (f in files) {
            out.write(f.data)
            out.write(13); out.write(10)
        }
        return out.toByteArray()
    }

    companion object {
        const val DEFAULT_CHARSET = "ISO-8859-1"

        fun canonicalKey(k: String): String {
            val out = StringBuilder()
            var upper = true
            for (ch in k) {
                out.append(if (upper) ch.uppercaseChar() else ch.lowercaseChar())
                upper = ch == '-'
            }
            return out.toString()
        }

        /** Parses a message in Winlink wire format. */
        fun parse(data: ByteArray): Message {
            val m = Message()
            var i = 0
            while (i < data.size && data[i].u in intArrayOf(9, 10, 11, 12, 13, 32)) i += 1
            var sawHeader = false
            var last: String? = null
            while (true) {
                var nl = i
                while (nl < data.size && data[nl] != 10.toByte()) nl += 1
                if (nl >= data.size) throw MessageException.malformed("unterminated header")
                var end = nl
                if (end > i && data[end - 1] == 13.toByte()) end -= 1
                val line = data.copyOfRange(i, end)
                i = nl + 1
                if (line.isEmpty()) break
                // Header lines should be ASCII, but some gateways pass raw ISO-8859-1 through.
                val text = decodeUTF8Strict(line) ?: String(line, Charsets.ISO_8859_1)
                if ((line[0] == 32.toByte() || line[0] == 9.toByte()) && last != null) {
                    // Folded continuation line.
                    val vs = m._header[last]!!
                    vs[vs.size - 1] = vs[vs.size - 1] + " " + text.trim()
                    continue
                }
                val colon = text.indexOf(':')
                if (colon < 0) throw MessageException.malformed("bad header line: $text")
                val key = canonicalKey(text.substring(0, colon).trim())
                val value = text.substring(colon + 1).trim()
                m._header.getOrPut(key) { mutableListOf() }.add(value)
                last = key
                sawHeader = true
            }
            if (!sawHeader) throw MessageException.malformed("no header")

            fun section(n: Int): ByteArray {
                if (i + n > data.size) throw MessageException.malformed("section shorter than declared")
                val s = data.copyOfRange(i, i + n)
                i += n
                if (i < data.size) {
                    if (!(data.size - i >= 2 && data[i] == 13.toByte() && data[i + 1] == 10.toByte())) {
                        throw MessageException.malformed("unexpected end of section")
                    }
                    i += 2
                }
                return s
            }

            m.body = section(m.bodySize)
            for (value in m.values("File")) {
                val parts = value.split(" ", limit = 2)
                val size = parts.getOrNull(0)?.toIntOrNull()
                if (parts.size != 2 || size == null) throw MessageException.malformed("bad File header: $value")
                m.files += Attachment(MIMEWords.decode(parts[1]), section(size))
            }
            if (m.field("Date").isNotEmpty() && parseDate(m.field("Date")) == null) {
                throw MessageException.malformed("unparseable Date: ${m.field("Date")}")
            }
            return m
        }

        // Helpers

        internal fun canBeLatin1(s: String) = Charsets.ISO_8859_1.newEncoder().canEncode(s)

        internal fun decodeUTF8Strict(b: ByteArray): String? = try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(b)).toString()
        } catch (_: CharacterCodingException) {
            null
        }

        fun encode(s: String, charset: String): ByteArray =
            if (charset.uppercase() == "UTF-8") s.toByteArray(Charsets.UTF_8) else s.toByteArray(Charsets.ISO_8859_1)

        fun decode(b: ByteArray, charset: String): String = when (charset.uppercase()) {
            "UTF-8", "UTF8", "US-ASCII", "ASCII" -> String(b, Charsets.UTF_8)
            else -> String(b, Charsets.ISO_8859_1)
        }

        /** A 12 character MID: base32 of an MD5 over the call sign, time and some randomness. */
        fun generateMID(callsign: String): String {
            val payload = "${System.currentTimeMillis()}-${UUID.randomUUID()}-$callsign"
            val sum = MessageDigest.getInstance("MD5").digest(payload.toByteArray())
            return base32(sum).take(12)
        }

        internal fun base32(b: ByteArray): String {
            val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
            val out = StringBuilder()
            var acc = 0
            var bits = 0
            for (byte in b) {
                acc = ((acc shl 8) or byte.u) and 0xffff
                bits += 8
                while (bits >= 5) {
                    out.append(alphabet[(acc shr (bits - 5)) and 31])
                    bits -= 5
                }
            }
            if (bits > 0) out.append(alphabet[(acc shl (5 - bits)) and 31])
            return out.toString()
        }

        private val utcFormatters: List<DateTimeFormatter> = listOf(
            "yyyy/MM/dd HH:mm", "yyyy.MM.dd HH:mm", "yyyy-MM-dd HH:mm", "yyyyMMddHHmmss",
            "EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z",
        ).map { DateTimeFormatter.ofPattern(it, Locale.US).withZone(ZoneOffset.UTC) }

        fun formatDate(d: Instant): String = utcFormatters[0].format(d)

        fun parseDate(s: String): Instant? {
            if (s.isEmpty()) return null
            // Drop a trailing comment such as "(UTC)".
            val trimmed = s.replace(Regex("""\s*\(.*\)$"""), "")
            for (f in utcFormatters) {
                try {
                    return Instant.from(f.parse(trimmed))
                } catch (_: Exception) {
                }
            }
            return null
        }
    }
}

/** RFC 2047 encoded words, as used for Subject and File headers. */
object MIMEWords {
    /** Q-encodes [s] if it holds anything but printable ASCII (ISO-8859-1 when it fits, else UTF-8). */
    fun encode(s: String): String {
        if (s.all { it.code in 0x20..0x7e || it == '\t' }) return s
        val latin = Message.canBeLatin1(s)
        val charset = if (latin) "ISO-8859-1" else "UTF-8"
        val bytes = Message.encode(s, charset)
        val prefix = "=?$charset?q?"
        val maxEncoded = 75 - prefix.length - 2
        val words = mutableListOf<String>()
        var cur = StringBuilder()
        // Keep multi-byte UTF-8 sequences inside one word.
        var i = 0
        while (i < bytes.size) {
            var n = 1
            val b0 = bytes[i].u
            if (!latin && b0 >= 0xC0) n = if (b0 >= 0xF0) 4 else if (b0 >= 0xE0) 3 else 2
            val piece = StringBuilder()
            for (j in i until minOf(i + n, bytes.size)) {
                val b = bytes[j].u
                when (b) {
                    0x20 -> piece.append('_')
                    in 0x30..0x39, in 0x41..0x5A, in 0x61..0x7A, 0x21, 0x2A, 0x2B, 0x2D, 0x2F -> piece.append(b.toChar())
                    else -> piece.append(String.format("=%02X", b))
                }
            }
            if (cur.length + piece.length > maxEncoded) {
                words += "$prefix$cur?="
                cur = StringBuilder()
            }
            cur.append(piece)
            i += n
        }
        if (cur.isNotEmpty() || words.isEmpty()) words += "$prefix$cur?="
        return words.joinToString(" ")
    }

    private val wordPattern = Regex("""=\?([^?]+)\?([QqBb])\?([^?]*)\?=""")

    /** Decodes encoded words; text without them is returned as is. */
    fun decode(s: String): String {
        if (!s.contains("=?")) return s
        val out = StringBuilder()
        var last = 0
        var prevWasWord = false
        for (m in wordPattern.findAll(s)) {
            val gap = s.substring(last, m.range.first)
            // Whitespace between adjacent encoded words is dropped.
            if (!(prevWasWord && gap.isBlank())) out.append(gap)
            val charset = m.groupValues[1]
            val enc = m.groupValues[2].uppercase()
            val text = m.groupValues[3]
            val bytes: ByteArray
            if (enc == "B") {
                bytes = try {
                    java.util.Base64.getDecoder().decode(text)
                } catch (_: IllegalArgumentException) {
                    text.toByteArray()
                }
            } else {
                val u = text.toByteArray()
                val b = java.io.ByteArrayOutputStream()
                var i = 0
                while (i < u.size) {
                    val v = if (u[i] == '='.code.toByte() && i + 2 < u.size) String(u, i + 1, 2).toIntOrNull(16) else null
                    if (u[i] == '_'.code.toByte()) {
                        b.write(0x20)
                    } else if (v != null) {
                        b.write(v)
                        i += 2
                    } else {
                        b.write(u[i].u)
                    }
                    i += 1
                }
                bytes = b.toByteArray()
            }
            out.append(Message.decode(bytes, charset))
            last = m.range.last + 1
            prevWasWord = true
        }
        out.append(s.substring(last))
        return out.toString()
    }
}
