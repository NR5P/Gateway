import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import WinlinkKit

final class LinkSpeedTests: XCTestCase {
    func testParseBitrateLines() {
        let tx = LinkSpeed.parse("(7)  549 bps TX", mode: .hf, bandwidth: "2300")
        XCTAssertEqual(tx, LinkSpeed(level: 7, bps: 549, transmitting: true, modulation: "6 carriers · QPSK"))
        let rx = LinkSpeed.parse(" (4)  175 bps RX", mode: .hf, bandwidth: "2300")
        XCTAssertEqual(rx, LinkSpeed(level: 4, bps: 175, transmitting: false, modulation: "FSK"))
        XCTAssertEqual(LinkSpeed.parse("(16)  7050 bps TX", mode: .hf, bandwidth: "2300")?.modulation, "OFDM 49 carriers · 32QAM")
        XCTAssertEqual(LinkSpeed.parse("(4)  175 bps TX", mode: .hf, bandwidth: "500")?.modulation, "2 carriers · BPSK")
        XCTAssertEqual(LinkSpeed.parse("(10)  2400 bps TX", mode: .hf, bandwidth: "2750")?.modulation, "13 carriers · QPSK")
        XCTAssertNil(LinkSpeed.parse("(3)  1200 bps TX", mode: .fm, bandwidth: nil)?.modulation)
        XCTAssertEqual(LinkSpeed.parse("(3)  1200 bps TX", mode: .fm, bandwidth: nil)?.bps, 1200)
        XCTAssertNil(LinkSpeed.parse("garbage", mode: .hf, bandwidth: "2300"))
        XCTAssertNil(LinkSpeed.modulation(level: 17, bandwidth: "2300"))
    }
}

final class ImageShrinkerTests: XCTestCase {
    /// A 4000 x 3000 photo-like JPEG (smooth shading with fine detail), a few MB like a phone's.
    static func photo(width: Int = 4000, height: Int = 3000) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var rng = SystemRandomNumberGenerator()
        for y in stride(from: 0, to: height, by: 20) {
            for x in stride(from: 0, to: width, by: 20) {
                let n = Double(UInt8.random(in: 0...40, using: &rng)) / 255
                ctx.setFillColor(red: Double(x) / Double(width) * 0.8 + n, green: Double(y) / Double(height) * 0.7 + n,
                                 blue: 0.5 + n, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 20, height: 20))
            }
        }
        let out = NSMutableData()
        let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dst))
        return out as Data
    }

    func testPhotoShrinksToRadioSize() throws {
        let big = Self.photo()
        XCTAssertGreaterThan(big.count, 500_000)
        let r = try XCTUnwrap(ImageShrinker.shrink(big))
        XCTAssertLessThanOrEqual(r.data.count, ImageShrinker.targetBytes, "\(r.data.count) bytes")
        XCTAssertLessThanOrEqual(max(r.width, r.height), 640)
        XCTAssertEqual(r.width * 3, r.height * 4, "aspect ratio kept")
        // It is a JPEG that decodes.
        let src = try XCTUnwrap(CGImageSourceCreateWithData(r.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(src) as String?, UTType.jpeg.identifier)
    }

    func testNotAnImage() {
        XCTAssertNil(ImageShrinker.shrink(Data("hello".utf8)))
    }

    func testNamesAndTypes() {
        XCTAssertEqual(ImageShrinker.jpegName("IMG_1234.HEIC"), "IMG_1234.jpg")
        XCTAssertEqual(ImageShrinker.jpegName(".png"), "photo.jpg")
        XCTAssertTrue(ImageShrinker.isPhoto(.heic))
        XCTAssertTrue(ImageShrinker.isPhoto(.jpeg))
        XCTAssertFalse(ImageShrinker.isPhoto(.gif))
        XCTAssertFalse(ImageShrinker.isPhoto(.pdf))
    }
}
