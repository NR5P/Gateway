// LZHUF compression as used by the FBB B2 forwarding protocol (B2F).
//
// Ported from la5nta/wl2k-go's lzhuf package (MIT, Martin Hebnes Pedersen),
// itself a port of lzhuf.c from JNOS 2, by way of the Swift WinlinkKit. See
// WinlinkKit/COPYRIGHT.lzhuf for the history and licence of the original code.
//
// The B2 format is: CRC16 of everything after it (2 bytes LE), the
// uncompressed size (4 bytes LE), then the compressed bit stream.

package com.nr5p.winlink

class LZHUFException(val kind: Kind) : Exception(kind.name) {
    enum class Kind { UNEXPECTED_EOF, CHECKSUM }
}

object LZHUF {
    /** Compresses [data], prepending the CRC16 when [crc] is true (the B2 format). */
    fun compress(data: ByteArray, crc: Boolean = true): ByteArray {
        val w = Encoder()
        w.write(data)
        val body = w.finish()
        val size = data.size
        val lengthBytes = byteArrayOf(size.toByte(), (size shr 8).toByte(), (size shr 16).toByte(), (size ushr 24).toByte())
        if (!crc) return lengthBytes + body
        val sum = CRC16.checksum(lengthBytes + body)
        return byteArrayOf(sum.toByte(), (sum shr 8).toByte()) + lengthBytes + body
    }

    /** Decompresses B2 data, verifying the CRC16 when [crc] is true. */
    fun decompress(data: ByteArray, crc: Boolean = true): ByteArray {
        var i = 0
        var wantCRC = 0
        if (crc) {
            if (data.size < 2) throw LZHUFException(LZHUFException.Kind.UNEXPECTED_EOF)
            wantCRC = data[0].u or (data[1].u shl 8)
            i = 2
        }
        val summed = data.copyOfRange(i, data.size)
        if (summed.size < 4) throw LZHUFException(LZHUFException.Kind.UNEXPECTED_EOF)
        val size = summed[0].u or (summed[1].u shl 8) or (summed[2].u shl 16) or (summed[3].u shl 24)
        if (size < 0) throw LZHUFException(LZHUFException.Kind.CHECKSUM)
        val out = Decoder(summed.copyOfRange(4, summed.size)).decode(size)
        if (crc && CRC16.checksum(summed) != wantCRC) throw LZHUFException(LZHUFException.Kind.CHECKSUM)
        return out
    }
}

internal val Byte.u: Int get() = toInt() and 0xff

// Shared adaptive Huffman / LZSS state

private const val N = 2048 // ring buffer size
private const val F = 60 // lookahead size
private const val NIL = N // leaf of tree
private const val THRESHOLD = 2
private const val NUM_CHAR = 256 - THRESHOLD + F // kinds of characters
private const val T = NUM_CHAR * 2 - 1 // table size
private const val R = T - 1 // root position
private const val MAX_FREQ = 0x8000

private class Tree {
    val freq = IntArray(T + 1)
    val prnt = IntArray(T + NUM_CHAR)
    val son = IntArray(T)
    val dad = IntArray(N + 1)
    val lson = IntArray(N + 1)
    val rson = IntArray(N + 257)
    val textBuf = IntArray(N + F - 1)
    var matchLength = 0
    var matchPosition = 0

    init {
        for (i in 0 until NUM_CHAR) {
            freq[i] = 1
            son[i] = i + T
            prnt[i + T] = i
        }
        var i = 0
        var j = NUM_CHAR
        while (j <= R) {
            freq[j] = freq[i] + freq[i + 1]
            son[j] = i
            prnt[i] = j
            prnt[i + 1] = j
            i += 2
            j += 1
        }
        freq[T] = 0xffff
        prnt[R] = 0
    }

    fun initTree() {
        for (i in (N + 1)..(N + 256)) rson[i] = NIL
        for (i in 0 until N) dad[i] = NIL
    }

    fun deleteNode(p: Int) {
        if (dad[p] == NIL) return
        var q: Int
        if (rson[p] == NIL) {
            q = lson[p]
        } else if (lson[p] == NIL) {
            q = rson[p]
        } else {
            q = lson[p]
            if (rson[q] != NIL) {
                while (rson[q] != NIL) q = rson[q]
                rson[dad[q]] = lson[q]
                dad[lson[q]] = dad[q]
                lson[q] = lson[p]
                dad[lson[p]] = q
            }
            rson[q] = rson[p]
            dad[rson[p]] = q
        }
        dad[q] = dad[p]
        if (rson[dad[p]] == p) rson[dad[p]] = q else lson[dad[p]] = q
        dad[p] = NIL
    }

    fun insertNode(r: Int) {
        var cmp = 1
        var p = N + 1 + textBuf[r]
        rson[r] = NIL
        lson[r] = NIL
        matchLength = 0
        while (true) {
            if (cmp >= 0) {
                if (rson[p] != NIL) {
                    p = rson[p]
                } else {
                    rson[p] = r
                    dad[r] = p
                    return
                }
            } else {
                if (lson[p] != NIL) {
                    p = lson[p]
                } else {
                    lson[p] = r
                    dad[r] = p
                    return
                }
            }
            var i = 1
            while (i < F) {
                cmp = textBuf[r + i] - textBuf[p + i]
                if (cmp != 0) break
                i += 1
            }
            if (i > THRESHOLD) {
                if (i > matchLength) {
                    matchPosition = ((r - p) and (N - 1)) - 1
                    matchLength = i
                    if (matchLength >= F) break
                }
                if (i == matchLength) {
                    val c = ((r - p) and (N - 1)) - 1
                    if (c < matchPosition) matchPosition = c
                }
            }
        }
        dad[r] = dad[p]
        lson[r] = lson[p]
        rson[r] = rson[p]
        dad[lson[p]] = r
        dad[rson[p]] = r
        if (rson[dad[p]] == p) rson[dad[p]] = r else lson[dad[p]] = r
        dad[p] = NIL
    }

    private fun reconst() {
        var j = 0
        for (i in 0 until T) {
            if (son[i] >= T) {
                freq[j] = (freq[i] + 1) / 2
                son[j] = son[i]
                j += 1
            }
        }
        var i = 0
        j = NUM_CHAR
        while (j < T) {
            val k0 = i + 1
            freq[j] = freq[i] + freq[k0]
            val first = freq[j]
            var k = j
            while (first < freq[k - 1]) k -= 1
            val last = j - k
            if (last > 0) {
                for (m in (k + last - 1) downTo k) {
                    freq[m + 1] = freq[m]
                    son[m + 1] = son[m]
                }
            }
            freq[k] = first
            son[k] = i
            i += 2
            j += 1
        }
        for (n in 0 until T) {
            val k = son[n]
            if (k >= T) {
                prnt[k] = n
            } else {
                prnt[k] = n
                prnt[k + 1] = n
            }
        }
    }

    fun update(c0: Int) {
        if (freq[R] == MAX_FREQ) reconst()
        var c = prnt[c0 + T]
        while (true) {
            freq[c] += 1
            if (freq[c] <= freq[c + 1] || freq.size <= c + 2) {
                c = prnt[c]
                if (c == 0) break
                continue
            }
            var l = c + 1
            val k = freq[c]
            while (k > freq[l + 1]) l += 1
            freq[c] = freq[l]
            freq[l] = k

            val i = son[c]
            prnt[i] = l
            if (i < T) prnt[i + 1] = l

            val j = son[l]
            son[l] = i

            prnt[j] = c
            if (j < T) prnt[j + 1] = c
            son[c] = j

            c = prnt[l]
            if (c == 0) break
        }
    }
}

private class Encoder {
    val z = Tree()
    val buf = java.io.ByteArrayOutputStream()
    var putbuf = 0L
    var putlen = 0
    var len = 0
    var r = N - F
    var s = 0
    var lastMatchLength = 0
    var preFilled = false

    init {
        z.initTree()
        for (i in 0 until r) z.textBuf[i] = 0x20
    }

    fun write(p: ByteArray) {
        var n = 0
        while (!preFilled && n < p.size) {
            z.textBuf[r + len] = p[n].u
            n += 1
            len += 1
            z.insertNode(r - len)
            lastMatchLength = 1
            preFilled = len == F
        }
        while (n < p.size) {
            advance(p[n].u)
            n += 1
        }
    }

    fun finish(): ByteArray {
        while (len > 0) advance(-1)
        encode()
        if (putlen != 0) buf.write((putbuf shr 8).toInt() and 0xff)
        return buf.toByteArray()
    }

    private fun advance(c: Int) {
        if (c >= 0) {
            z.textBuf[s] = c
            if (s < F - 1) z.textBuf[s + N] = c
            len += 1
        }
        z.insertNode(r)
        lastMatchLength -= 1
        if (lastMatchLength == 0) encode()
        z.deleteNode(s)
        s = (s + 1) and (N - 1)
        r = (r + 1) and (N - 1)
        len -= 1
    }

    private fun encode() {
        if (len == 0) return
        if (z.matchLength > len) z.matchLength = len
        if (z.matchLength <= THRESHOLD) {
            z.matchLength = 1
            encodeChar(z.textBuf[r])
        } else {
            encodeChar(255 - THRESHOLD + z.matchLength)
            encodePosition(z.matchPosition)
        }
        lastMatchLength = z.matchLength
    }

    private fun encodeChar(c: Int) {
        var i = 0L
        var j = 0
        var k = z.prnt[c + T]
        do {
            i = i shr 1
            j += 1
            if (k and 1 != 0) i += 0x8000
            k = z.prnt[k]
        } while (k != R)
        putCode(j, i)
        z.update(c)
    }

    private fun encodePosition(c: Int) {
        val i = c shr 6
        putCode(P_LEN[i], P_CODE[i].toLong() shl 8)
        putCode(6, (c and 0x3f).toLong() shl 10)
    }

    private fun putCode(l: Int, c: Long) {
        putbuf = putbuf or (c ushr putlen)
        putlen += l
        if (putlen < 8) return
        buf.write((putbuf shr 8).toInt() and 0xff)
        putlen -= 8
        if (putlen >= 8) {
            buf.write(putbuf.toInt() and 0xff)
            putlen -= 8
            putbuf = c shl (l - putlen)
        } else {
            putbuf = putbuf shl 8
        }
        putbuf = putbuf and 0xffff_ffffL
    }
}

private class Decoder(val bits: ByteArray) {
    val z = Tree()
    var byteIndex = 0
    var acc = 0L
    var accBits = 0
    var eof = false

    init {
        for (i in 0 until N - F) z.textBuf[i] = 0x20
    }

    private fun readBits(n: Int): Int {
        while (n > accBits) {
            if (byteIndex >= bits.size) {
                eof = true
                return 0
            }
            acc = (acc shl 8) or bits[byteIndex].u.toLong()
            byteIndex += 1
            accBits += 8
        }
        val v = (acc ushr (accBits - n)) and ((1L shl n) - 1)
        accBits -= n
        return v.toInt()
    }

    private fun decodeChar(): Int {
        var c = z.son[R]
        while (c < T) {
            c += readBits(1)
            c = z.son[c]
        }
        c -= T
        z.update(c)
        return c
    }

    private fun decodePosition(): Int {
        var i = readBits(8)
        val c = D_CODE[i] shl 6
        var j = D_LEN[i] - 2
        while (j > 0) {
            i = (i shl 1) + readBits(1)
            j -= 1
        }
        return c or (i and 0x3f)
    }

    fun decode(size: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream(size)
        var count = 0
        var r = N - F
        while (count < size && !eof) {
            val c = decodeChar()
            if (c < 256) {
                out.write(c)
                count += 1
                z.textBuf[r] = c
                r = (r + 1) and (N - 1)
                continue
            }
            val i = (r - decodePosition() - 1) and (N - 1)
            val j = c - 255 + THRESHOLD
            for (k in 0 until j) {
                val b = z.textBuf[(i + k) and (N - 1)]
                out.write(b)
                count += 1
                z.textBuf[r] = b
                r = (r + 1) and (N - 1)
            }
        }
        if (eof) throw LZHUFException(LZHUFException.Kind.UNEXPECTED_EOF)
        if (count != size) throw LZHUFException(LZHUFException.Kind.CHECKSUM)
        return out.toByteArray()
    }
}

private val P_CODE = intArrayOf(
    0x00, 0x20, 0x30, 0x40, 0x50, 0x58, 0x60, 0x68, 0x70, 0x78, 0x80, 0x88, 0x90, 0x94, 0x98, 0x9C,
    0xA0, 0xA4, 0xA8, 0xAC, 0xB0, 0xB4, 0xB8, 0xBC, 0xC0, 0xC2, 0xC4, 0xC6, 0xC8, 0xCA, 0xCC, 0xCE,
    0xD0, 0xD2, 0xD4, 0xD6, 0xD8, 0xDA, 0xDC, 0xDE, 0xE0, 0xE2, 0xE4, 0xE6, 0xE8, 0xEA, 0xEC, 0xEE,
    0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF,
)

private val P_LEN = intArrayOf(
    3, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
)

// D_CODE/D_LEN are the inverse of P_CODE/P_LEN: for every byte value, the upper
// six position bits and the code length it starts.
private val D_CODE = IntArray(256)
private val D_LEN = IntArray(256).also { len ->
    for (i in 0 until 64) {
        val width = 1 shl (8 - P_LEN[i])
        for (b in P_CODE[i] until P_CODE[i] + width) {
            D_CODE[b] = i
            len[b] = P_LEN[i]
        }
    }
}

/** CRC16, the XMODEM variant of CRC-CCITT, as used by Winlink/Airmail. */
object CRC16 {
    private val table = IntArray(256) { i ->
        var crc = i shl 8
        repeat(8) { crc = if (crc and 0x8000 != 0) ((crc shl 1) xor 0x1021) and 0xffff else (crc shl 1) and 0xffff }
        crc
    }

    fun checksum(data: ByteArray): Int {
        var sum = 0
        for (c in data) sum = step(c.u, sum)
        sum = step(0, sum)
        return step(0, sum)
    }

    private fun step(c: Int, sum: Int): Int = ((sum shl 8) and 0xff00) xor table[sum shr 8] xor c
}
