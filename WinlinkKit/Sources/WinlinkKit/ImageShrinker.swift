import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes a photo small enough to send over a radio link: scaled down, re-encoded as JPEG at the
/// highest quality that fits the target size, upright, and without its metadata (no location).
/// A full-size phone photo of 2-5 MB becomes about 20-30 KB, a minute or two at VARA HF speeds.
public enum ImageShrinker {
    public struct Result: Sendable {
        public var data: Data
        public var width: Int
        public var height: Int
    }

    /// The longest side to try, largest first, and the size to aim for.
    public static let sides = [640, 480, 320, 240]
    public static let targetBytes = 30_000

    /// Nil when `data` is not an image ImageIO can read.
    public static func shrink(_ data: Data, target: Int = targetBytes) -> Result? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        var best: Result?
        for side in sides {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, // EXIF orientation applied
                kCGImageSourceThumbnailMaxPixelSize: side,
            ]
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            for q in [0.7, 0.55, 0.4, 0.3, 0.2] {
                guard let jpeg = encode(img, quality: q) else { continue }
                let r = Result(data: jpeg, width: img.width, height: img.height)
                if best.map({ jpeg.count < $0.data.count }) ?? true { best = r }
                if jpeg.count <= target { return r }
            }
        }
        return best
    }

    /// True for the image types worth shrinking (not, say, a small GIF or an SVG).
    public static func isPhoto(_ type: UTType) -> Bool {
        type.conforms(to: .image) && !type.conforms(to: .gif) && !type.conforms(to: .svg)
    }

    private static func encode(_ img: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    /// "IMG_1234.HEIC" -> "IMG_1234.jpg".
    public static func jpegName(_ name: String) -> String {
        let base = name.lastIndex(of: ".").map { String(name[..<$0]) } ?? name
        return (base.isEmpty ? "photo" : base) + ".jpg"
    }
}
