// Vectors from la5nta/wl2k-go's lzhuf tests (MIT).

package com.nr5p.winlink

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

fun bytes(vararg b: Int) = ByteArray(b.size) { b[it].toByte() }

fun resource(name: String): ByteArray =
    LZHUFTest::class.java.classLoader!!.getResourceAsStream(name)!!.use { it.readBytes() }

class LZHUFTest {
    private val samples = listOf(
        "\n".toByteArray() to bytes(0xe, 0x8f, 0x1, 0x0, 0x0, 0x0, 0xcb, 0x0),
        "foo".toByteArray() to bytes(0xb6, 0x47, 0x3, 0x0, 0x0, 0x0, 0xf9, 0x7e, 0xf1, 0x0),
        "The quick brown fox jumps over the lazy dog\r\nThe quick brown fox jumps over the lazy dog".toByteArray() to bytes(
            0x76, 0x25, 0x58, 0x0, 0x0, 0x0, 0xf0, 0x7d, 0x3e, 0x3a, 0xcf, 0xe8, 0xf, 0xd7, 0xdf, 0xf7, 0xc2, 0xf7, 0x7f,
            0xbf, 0x60, 0x7f, 0xab, 0x7f, 0x2b, 0xa0, 0x4b, 0x7f, 0x6c, 0xf, 0xcf, 0xf3, 0xff, 0x55, 0x60, 0x2c, 0x3b,
            0xba, 0x80, 0x23, 0x3, 0xdf, 0x8f, 0x68, 0x30, 0x2d, 0x3f, 0xa, 0xff, 0x3c, 0xce, 0x5b, 0xf2, 0x2c,
        ),
        "bar".toByteArray() to bytes(0xc7, 0xef, 0x03, 0x00, 0x00, 0x00, 0xf7, 0x7b, 0x7f, 0xc0),
    )

    private val files = listOf("gettysburg.txt", "e.txt", "pi.txt", "LPE5NXDVLVSQ.b2f", "Mark.Twain-Tom.Sawyer.txt")

    @Test fun samplesCompress() {
        samples.forEachIndexed { i, (plain, compressed) -> assertArrayEquals("sample $i", compressed, LZHUF.compress(plain)) }
    }

    @Test fun samplesDecompress() {
        samples.forEachIndexed { i, (plain, compressed) -> assertArrayEquals("sample $i", plain, LZHUF.decompress(compressed)) }
    }

    @Test fun filesMatchReferenceCompressor() {
        for (name in files) {
            val plain = resource(name)
            val want = resource("$name.lzh")
            assertArrayEquals(name, want, LZHUF.compress(plain))
            assertArrayEquals(name, plain, LZHUF.decompress(want))
        }
    }

    @Test fun emptyRoundTrip() {
        val c = LZHUF.compress(ByteArray(0))
        assertEquals(6, c.size)
        assertArrayEquals(ByteArray(0), LZHUF.decompress(c))
    }

    private fun assertThrowsKind(kind: LZHUFException.Kind, f: () -> Unit) {
        try {
            f()
            fail("no error")
        } catch (e: LZHUFException) {
            assertEquals(kind, e.kind)
        }
    }

    @Test fun badChecksum() {
        val data = samples[0].second.copyOf()
        data[0] = 1
        assertThrowsKind(LZHUFException.Kind.CHECKSUM) { LZHUF.decompress(data) }
    }

    @Test fun truncated() {
        assertThrowsKind(LZHUFException.Kind.UNEXPECTED_EOF) { LZHUF.decompress(samples[2].second.copyOf(10)) }
        assertThrowsKind(LZHUFException.Kind.UNEXPECTED_EOF) { LZHUF.decompress(bytes(0)) }
    }

    @Test fun withoutCRC() {
        val (plain, compressed) = samples[2]
        val noCRC = compressed.copyOfRange(2, compressed.size)
        assertArrayEquals(plain, LZHUF.decompress(noCRC, crc = false))
        assertArrayEquals(noCRC, LZHUF.compress(plain, crc = false))
    }
}
