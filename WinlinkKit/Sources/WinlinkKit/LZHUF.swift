// LZHUF compression as used by the FBB B2 forwarding protocol (B2F).
//
// Ported from la5nta/wl2k-go's lzhuf package (MIT, Martin Hebnes Pedersen),
// itself a port of lzhuf.c from JNOS 2. See COPYRIGHT.lzhuf for the history
// and licence of the original code.
//
// The B2 format is: CRC16 of everything after it (2 bytes LE), the
// uncompressed size (4 bytes LE), then the compressed bit stream.

import Foundation

public enum LZHUFError: Error, Equatable {
    case unexpectedEOF
    case checksum
}

public enum LZHUF {
    /// Compresses `data`, prepending the CRC16 when `crc` is true (the B2 format).
    public static func compress(_ data: [UInt8], crc: Bool = true) -> [UInt8] {
        let w = Encoder()
        w.write(data)
        let body = w.finish()
        let size = UInt32(truncatingIfNeeded: data.count)
        let lengthBytes: [UInt8] = [UInt8(size & 0xff), UInt8(size >> 8 & 0xff), UInt8(size >> 16 & 0xff), UInt8(size >> 24)]
        var out: [UInt8] = []
        out.reserveCapacity(body.count + 6)
        if crc {
            let sum = CRC16.checksum(lengthBytes + body)
            out += [UInt8(sum & 0xff), UInt8(sum >> 8)]
        }
        out += lengthBytes
        out += body
        return out
    }

    /// Decompresses B2 data, verifying the CRC16 when `crc` is true.
    public static func decompress(_ data: [UInt8], crc: Bool = true) throws -> [UInt8] {
        var i = 0
        var wantCRC: UInt16 = 0
        if crc {
            guard data.count >= 2 else { throw LZHUFError.unexpectedEOF }
            wantCRC = UInt16(data[0]) | UInt16(data[1]) << 8
            i = 2
        }
        let summed = Array(data[i...])
        guard summed.count >= 4 else { throw LZHUFError.unexpectedEOF }
        let size = Int(Int32(bitPattern: UInt32(summed[0]) | UInt32(summed[1]) << 8 | UInt32(summed[2]) << 16 | UInt32(summed[3]) << 24))
        guard size >= 0 else { throw LZHUFError.checksum }
        let out = try Decoder(bits: Array(summed[4...])).decode(size: size)
        if crc && CRC16.checksum(summed) != wantCRC {
            throw LZHUFError.checksum
        }
        return out
    }
}

// MARK: - Shared adaptive Huffman / LZSS state

private let N = 2048 // ring buffer size
private let F = 60 // lookahead size
private let NIL = N // leaf of tree
private let threshold = 2
private let numChar = 256 - threshold + F // kinds of characters
private let T = numChar * 2 - 1 // table size
private let R = T - 1 // root position
private let maxFreq = 0x8000

private final class Tree {
    var freq = [Int](repeating: 0, count: T + 1)
    var prnt = [Int](repeating: 0, count: T + numChar)
    var son = [Int](repeating: 0, count: T)
    var dad = [Int](repeating: 0, count: N + 1)
    var lson = [Int](repeating: 0, count: N + 1)
    var rson = [Int](repeating: 0, count: N + 257)
    var textBuf = [UInt8](repeating: 0, count: N + F - 1)
    var matchLength = 0
    var matchPosition = 0

    init() {
        for i in 0..<numChar {
            freq[i] = 1
            son[i] = i + T
            prnt[i + T] = i
        }
        var i = 0
        var j = numChar
        while j <= R {
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

    func initTree() {
        for i in (N + 1)...(N + 256) { rson[i] = NIL }
        for i in 0..<N { dad[i] = NIL }
    }

    func deleteNode(_ p: Int) {
        if dad[p] == NIL { return }
        var q: Int
        if rson[p] == NIL {
            q = lson[p]
        } else if lson[p] == NIL {
            q = rson[p]
        } else {
            q = lson[p]
            if rson[q] != NIL {
                while rson[q] != NIL { q = rson[q] }
                rson[dad[q]] = lson[q]
                dad[lson[q]] = dad[q]
                lson[q] = lson[p]
                dad[lson[p]] = q
            }
            rson[q] = rson[p]
            dad[rson[p]] = q
        }
        dad[q] = dad[p]
        if rson[dad[p]] == p {
            rson[dad[p]] = q
        } else {
            lson[dad[p]] = q
        }
        dad[p] = NIL
    }

    func insertNode(_ r: Int) {
        var cmp = 1
        var p = N + 1 + Int(textBuf[r])
        rson[r] = NIL
        lson[r] = NIL
        matchLength = 0
        while true {
            if cmp >= 0 {
                if rson[p] != NIL {
                    p = rson[p]
                } else {
                    rson[p] = r
                    dad[r] = p
                    return
                }
            } else {
                if lson[p] != NIL {
                    p = lson[p]
                } else {
                    lson[p] = r
                    dad[r] = p
                    return
                }
            }
            var i = 1
            while i < F {
                cmp = Int(textBuf[r + i]) - Int(textBuf[p + i])
                if cmp != 0 { break }
                i += 1
            }
            if i > threshold {
                if i > matchLength {
                    matchPosition = ((r - p) & (N - 1)) - 1
                    matchLength = i
                    if matchLength >= F { break }
                }
                if i == matchLength {
                    let c = ((r - p) & (N - 1)) - 1
                    if c < matchPosition { matchPosition = c }
                }
            }
        }
        dad[r] = dad[p]
        lson[r] = lson[p]
        rson[r] = rson[p]
        dad[lson[p]] = r
        dad[rson[p]] = r
        if rson[dad[p]] == p {
            rson[dad[p]] = r
        } else {
            lson[dad[p]] = r
        }
        dad[p] = NIL
    }

    private func reconst() {
        var j = 0
        for i in 0..<T where son[i] >= T {
            freq[j] = (freq[i] + 1) / 2
            son[j] = son[i]
            j += 1
        }
        var i = 0
        j = numChar
        while j < T {
            let k0 = i + 1
            freq[j] = freq[i] + freq[k0]
            let first = freq[j]
            var k = j
            while first < freq[k - 1] { k -= 1 }
            let last = j - k
            if last > 0 {
                for m in stride(from: k + last - 1, through: k, by: -1) {
                    freq[m + 1] = freq[m]
                    son[m + 1] = son[m]
                }
            }
            freq[k] = first
            son[k] = i
            i += 2
            j += 1
        }
        for i in 0..<T {
            let k = son[i]
            if k >= T {
                prnt[k] = i
            } else {
                prnt[k] = i
                prnt[k + 1] = i
            }
        }
    }

    func update(_ c0: Int) {
        if freq[R] == maxFreq { reconst() }
        var c = prnt[c0 + T]
        while true {
            freq[c] += 1
            if freq[c] <= freq[c + 1] || freq.count <= c + 2 {
                c = prnt[c]
                if c == 0 { break }
                continue
            }
            var l = c + 1
            let k = freq[c]
            while k > freq[l + 1] { l += 1 }
            freq[c] = freq[l]
            freq[l] = k

            let i = son[c]
            prnt[i] = l
            if i < T { prnt[i + 1] = l }

            let j = son[l]
            son[l] = i

            prnt[j] = c
            if j < T { prnt[j + 1] = c }
            son[c] = j

            c = prnt[l]
            if c == 0 { break }
        }
    }
}

// MARK: - Encoder

private final class Encoder {
    let z = Tree()
    var buf: [UInt8] = []
    var putbuf: UInt = 0
    var putlen = 0
    var len = 0
    var r = N - F
    var s = 0
    var lastMatchLength = 0
    var preFilled = false

    init() {
        z.initTree()
        for i in 0..<r { z.textBuf[i] = 0x20 }
    }

    func write(_ p: [UInt8]) {
        var n = 0
        while !preFilled && n < p.count {
            z.textBuf[r + len] = p[n]
            n += 1
            len += 1
            z.insertNode(r - len)
            lastMatchLength = 1
            preFilled = len == F
        }
        while n < p.count {
            advance(p[n])
            n += 1
        }
    }

    func finish() -> [UInt8] {
        while len > 0 { advance(nil) }
        encode()
        if putlen != 0 { buf.append(UInt8(truncatingIfNeeded: putbuf >> 8)) }
        return buf
    }

    private func advance(_ c: UInt8?) {
        if let c {
            z.textBuf[s] = c
            if s < F - 1 { z.textBuf[s + N] = c }
            len += 1
        }
        z.insertNode(r)
        lastMatchLength -= 1
        if lastMatchLength == 0 { encode() }
        z.deleteNode(s)
        s = (s + 1) & (N - 1)
        r = (r + 1) & (N - 1)
        len -= 1
    }

    private func encode() {
        if len == 0 { return }
        if z.matchLength > len { z.matchLength = len }
        if z.matchLength <= threshold {
            z.matchLength = 1
            encodeChar(Int(z.textBuf[r]))
        } else {
            encodeChar(255 - threshold + z.matchLength)
            encodePosition(z.matchPosition)
        }
        lastMatchLength = z.matchLength
    }

    private func encodeChar(_ c: Int) {
        var i: UInt = 0
        var j = 0
        var k = z.prnt[c + T]
        repeat {
            i >>= 1
            j += 1
            if k & 1 != 0 { i += 0x8000 }
            k = z.prnt[k]
        } while k != R
        putCode(j, i)
        z.update(c)
    }

    private func encodePosition(_ c: Int) {
        let i = c >> 6
        putCode(Int(pLen[i]), UInt(pCode[i]) << 8)
        putCode(6, UInt(c & 0x3f) << 10)
    }

    private func putCode(_ l: Int, _ c: UInt) {
        putbuf |= c >> UInt(putlen)
        putlen += l
        if putlen < 8 { return }
        buf.append(UInt8(truncatingIfNeeded: putbuf >> 8))
        putlen -= 8
        if putlen >= 8 {
            buf.append(UInt8(truncatingIfNeeded: putbuf))
            putlen -= 8
            putbuf = c << UInt(l - putlen)
        } else {
            putbuf <<= 8
        }
        putbuf &= 0xffff_ffff
    }
}

// MARK: - Decoder

private final class Decoder {
    let z = Tree()
    let bits: [UInt8]
    var byteIndex = 0
    var acc: UInt64 = 0
    var accBits = 0
    var eof = false

    init(bits: [UInt8]) {
        self.bits = bits
        for i in 0..<(N - F) { z.textBuf[i] = 0x20 }
    }

    private func readBits(_ n: Int) -> Int {
        while n > accBits {
            guard byteIndex < bits.count else {
                eof = true
                return 0
            }
            acc = (acc << 8) | UInt64(bits[byteIndex])
            byteIndex += 1
            accBits += 8
        }
        let v = (acc >> UInt64(accBits - n)) & ((1 << UInt64(n)) - 1)
        accBits -= n
        return Int(v)
    }

    private func decodeChar() -> Int {
        var c = z.son[R]
        while c < T {
            c += readBits(1)
            c = z.son[c]
        }
        c -= T
        z.update(c)
        return c
    }

    private func decodePosition() -> Int {
        var i = readBits(8)
        let c = Int(dCode[i]) << 6
        var j = Int(dLen[i]) - 2
        while j > 0 {
            i = (i << 1) + readBits(1)
            j -= 1
        }
        return c | (i & 0x3f)
    }

    func decode(size: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(size)
        var r = N - F
        while out.count < size && !eof {
            let c = decodeChar()
            if c < 256 {
                out.append(UInt8(c))
                z.textBuf[r] = UInt8(c)
                r = (r + 1) & (N - 1)
                continue
            }
            let i = (r - decodePosition() - 1) & (N - 1)
            let j = c - 255 + threshold
            for k in 0..<j {
                let b = z.textBuf[(i + k) & (N - 1)]
                out.append(b)
                z.textBuf[r] = b
                r = (r + 1) & (N - 1)
            }
        }
        if eof { throw LZHUFError.unexpectedEOF }
        if out.count != size { throw LZHUFError.checksum }
        return out
    }
}

// MARK: - Tables

private let pCode: [UInt8] = [
    0x00, 0x20, 0x30, 0x40, 0x50, 0x58, 0x60, 0x68, 0x70, 0x78, 0x80, 0x88, 0x90, 0x94, 0x98, 0x9C,
    0xA0, 0xA4, 0xA8, 0xAC, 0xB0, 0xB4, 0xB8, 0xBC, 0xC0, 0xC2, 0xC4, 0xC6, 0xC8, 0xCA, 0xCC, 0xCE,
    0xD0, 0xD2, 0xD4, 0xD6, 0xD8, 0xDA, 0xDC, 0xDE, 0xE0, 0xE2, 0xE4, 0xE6, 0xE8, 0xEA, 0xEC, 0xEE,
    0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF,
]

private let pLen: [UInt8] = [
    3, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
]

// dCode/dLen are the inverse of pCode/pLen: for every byte value, the upper
// six position bits and the code length it starts.
private let (dCode, dLen): ([UInt8], [UInt8]) = {
    var code = [UInt8](repeating: 0, count: 256)
    var len = [UInt8](repeating: 0, count: 256)
    for i in 0..<64 {
        let width = 1 << (8 - Int(pLen[i]))
        for b in Int(pCode[i])..<(Int(pCode[i]) + width) {
            code[b] = UInt8(i)
            len[b] = pLen[i]
        }
    }
    return (code, len)
}()

// MARK: - CRC16 (XMODEM variant of CRC-CCITT, as used by Winlink/Airmail)

public enum CRC16 {
    public static func checksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt16 = 0
        for c in data { sum = step(c, sum) }
        sum = step(0, sum)
        return step(0, sum)
    }

    private static func step(_ c: UInt8, _ sum: UInt16) -> UInt16 {
        ((sum << 8) & 0xff00) ^ table[Int(sum >> 8)] ^ UInt16(c)
    }

    private static let table: [UInt16] = (0..<256).map { i in
        var crc = UInt16(i) << 8
        for _ in 0..<8 {
            crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
        }
        return crc
    }
}
