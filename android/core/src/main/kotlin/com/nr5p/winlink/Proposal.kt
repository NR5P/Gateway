// B2F message proposals ("FC EM <MID> <size> <compressed size> 0").
//
// Ported from la5nta/wl2k-go's fbb package (MIT, Martin Hebnes Pedersen).

package com.nr5p.winlink

import java.security.MessageDigest

enum class ProposalAnswer(val code: Char) {
    ACCEPT('+'),
    REJECT('-'),
    DEFER('='),
}

class Proposal internal constructor(
    var code: Char = 'C',
    var msgType: String = "EM",
    var mid: String,
    var title: String,
    var size: Int,
    var compressedSize: Int,
    var compressedData: ByteArray = ByteArray(0),
) {
    var answer: ProposalAnswer? = null
    var offset = 0

    companion object {
        /** An outbound proposal: [data] is the message in wire format. */
        fun outbound(mid: String, title: String, data: ByteArray): Proposal {
            val compressed = LZHUF.compress(data)
            return Proposal(
                mid = mid, title = title.ifEmpty { "No title" }, size = data.size,
                compressedSize = compressed.size, compressedData = compressed,
            )
        }

        fun of(message: Message): Proposal {
            message.validate()
            return outbound(message.mid, message.subject, message.bytes())
        }

        /** Parses "FC EM TJKYEIMMHSRB 527 123 0". */
        internal fun parse(line: String): Proposal {
            if (line.length < 4 || line[0] != 'F') throw B2FException("Unexpected end of proposal line")
            val code = line[1]
            if (code !in "CDAB") throw B2FException("Unsupported proposal code '$code'")
            val parts = line.substring(3).split(" ")
            if (code == 'A' || code == 'B') {
                // Not supported; keep enough to defer it.
                return Proposal(code, parts.firstOrNull() ?: "", parts.getOrElse(1) { "" }, "", 0, 0)
            }
            if (parts.size < 5) throw B2FException("Malformed proposal: $line")
            if (parts.size != 5) throw B2FException("Too many parts in proposal: $line")
            if (parts[0] != "EM" && parts[0] != "CM") throw B2FException("Expected message type CM or EM, but found ${parts[0]}")
            return Proposal(code, parts[0], parts[1], "", parts[2].toIntOrNull() ?: 0, parts[3].toIntOrNull() ?: 0)
        }

        /** Ascending size, then stable by precedence (as wl2k-go sorts outbound proposals). */
        internal fun sorted(props: List<Proposal>): List<Proposal> =
            props.sortedWith(compareBy<Proposal> { it.compressedSize }.thenBy { it.mid })
                .sortedBy { it.precedence } // sortedBy is stable

        /** Applies an "FS ..." answer line to [props], in order. */
        internal fun applyAnswer(line: String, props: List<Proposal>) {
            val s = if (line.startsWith("FS ")) line.substring(3) else line
            var j = 0
            var i = 0
            while (j < s.length) {
                if (i >= props.size) throw B2FException("Got answer for more proposals than expected")
                val c = s[j++]
                when (c) {
                    'Y', 'y', '+' -> props[i].answer = ProposalAnswer.ACCEPT
                    'N', 'n', 'R', 'r', '-' -> props[i].answer = ProposalAnswer.REJECT
                    'L', 'l', '=', 'H', 'h' -> props[i].answer = ProposalAnswer.DEFER
                    'A', 'a', '!' -> {
                        val start = j
                        while (j < s.length && s[j] in '0'..'9') j++
                        if (j == start) throw B2FException("Got offset request without offset index")
                        props[i].answer = ProposalAnswer.ACCEPT
                        val offset = s.substring(start, j).toLongOrNull() ?: 0
                        // The binary protocol cannot express offsets over 6 digits.
                        props[i].offset = if (offset > 999_999 || offset > props[i].compressedData.size) 0 else offset.toInt()
                    }
                    else -> throw B2FException("Invalid character ($c) in proposal answer line")
                }
                i += 1
            }
        }
    }

    internal val line: String get() = "F$code $msgType $mid $size $compressedSize 0"

    /** Lower is more urgent (winlink.org message precedence). */
    internal val precedence: Int
        get() = when {
            title.contains("//WL2K Z/") -> 0
            title.contains("//WL2K O/") -> 1
            title.contains("//WL2K P/") -> 2
            else -> 3
        }

    /** The decompressed message bytes. */
    fun data(): ByteArray {
        if (code != 'C') throw B2FException("unsupported compression $code")
        return LZHUF.decompress(compressedData)
    }

    fun message(): Message = Message.parse(data())
}

/** The Winlink secure login response to a ";PQ: <challenge>" line. Ported from wl2k-go (which took it from paclink-unix). */
object SecureLogin {
    private val salt = intArrayOf(
        77, 197, 101, 206, 190, 249, 93, 200, 51, 243, 93, 237, 71, 94, 239, 138, 68, 108, 70, 185, 225, 137, 217, 16,
        51, 122, 193, 48, 194, 195, 198, 175, 172, 169, 70, 84, 61, 62, 104, 186, 114, 52, 61, 168, 66, 129, 192, 208,
        187, 249, 232, 193, 41, 113, 41, 45, 240, 16, 29, 228, 208, 228, 61, 20,
    ).map { it.toByte() }.toByteArray()

    fun response(challenge: String, password: String): String {
        val payload = challenge.toByteArray() + password.toByteArray() + salt
        val sum = MessageDigest.getInstance("MD5").digest(payload)
        var pr = sum[3].u and 0x3f
        for (i in 2 downTo 0) pr = (pr shl 8) or sum[i].u
        return String.format("%08d", pr).takeLast(8)
    }
}
