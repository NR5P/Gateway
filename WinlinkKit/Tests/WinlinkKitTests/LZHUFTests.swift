// Vectors from la5nta/wl2k-go's lzhuf tests (MIT).

import XCTest
@testable import WinlinkKit

final class LZHUFTests: XCTestCase {
    static let samples: [(plain: [UInt8], compressed: [UInt8])] = [
        (Array("\n".utf8), [0xe, 0x8f, 0x1, 0x0, 0x0, 0x0, 0xcb, 0x0]),
        (Array("foo".utf8), [0xb6, 0x47, 0x3, 0x0, 0x0, 0x0, 0xf9, 0x7e, 0xf1, 0x0]),
        (
            Array("The quick brown fox jumps over the lazy dog\r\nThe quick brown fox jumps over the lazy dog".utf8),
            [0x76, 0x25, 0x58, 0x0, 0x0, 0x0, 0xf0, 0x7d, 0x3e, 0x3a, 0xcf, 0xe8, 0xf, 0xd7, 0xdf, 0xf7, 0xc2, 0xf7, 0x7f,
             0xbf, 0x60, 0x7f, 0xab, 0x7f, 0x2b, 0xa0, 0x4b, 0x7f, 0x6c, 0xf, 0xcf, 0xf3, 0xff, 0x55, 0x60, 0x2c, 0x3b,
             0xba, 0x80, 0x23, 0x3, 0xdf, 0x8f, 0x68, 0x30, 0x2d, 0x3f, 0xa, 0xff, 0x3c, 0xce, 0x5b, 0xf2, 0x2c]
        ),
        (Array("bar".utf8), [0xc7, 0xef, 0x03, 0x00, 0x00, 0x00, 0xf7, 0x7b, 0x7f, 0xc0]),
    ]

    static let files = ["gettysburg.txt", "e.txt", "pi.txt", "LPE5NXDVLVSQ.b2f", "Mark.Twain-Tom.Sawyer.txt"]

    func resource(_ name: String) throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Resources/\(name)", withExtension: nil))
        return Array(try Data(contentsOf: url))
    }

    func testSamplesCompress() {
        for (i, s) in Self.samples.enumerated() {
            XCTAssertEqual(LZHUF.compress(s.plain), s.compressed, "sample \(i)")
        }
    }

    func testSamplesDecompress() throws {
        for (i, s) in Self.samples.enumerated() {
            XCTAssertEqual(try LZHUF.decompress(s.compressed), s.plain, "sample \(i)")
        }
    }

    func testFilesMatchReferenceCompressor() throws {
        for name in Self.files {
            let plain = try resource(name)
            let want = try resource(name + ".lzh")
            XCTAssertEqual(LZHUF.compress(plain), want, name)
            XCTAssertEqual(try LZHUF.decompress(want), plain, name)
        }
    }

    func testEmptyRoundTrip() throws {
        let c = LZHUF.compress([])
        XCTAssertEqual(c.count, 6)
        XCTAssertEqual(try LZHUF.decompress(c), [])
    }

    func testBadChecksum() {
        var data = Self.samples[0].compressed
        data[0] = 1
        XCTAssertThrowsError(try LZHUF.decompress(data)) { XCTAssertEqual($0 as? LZHUFError, .checksum) }
    }

    func testTruncated() {
        XCTAssertThrowsError(try LZHUF.decompress(Array(Self.samples[2].compressed.prefix(10)))) {
            XCTAssertEqual($0 as? LZHUFError, .unexpectedEOF)
        }
        XCTAssertThrowsError(try LZHUF.decompress([0])) { XCTAssertEqual($0 as? LZHUFError, .unexpectedEOF) }
    }

    func testWithoutCRC() throws {
        let s = Self.samples[2]
        XCTAssertEqual(try LZHUF.decompress(Array(s.compressed.dropFirst(2)), crc: false), s.plain)
        XCTAssertEqual(LZHUF.compress(s.plain, crc: false), Array(s.compressed.dropFirst(2)))
    }
}
