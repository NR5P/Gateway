// B2F message proposals ("FC EM <MID> <size> <compressed size> 0").
//
// Ported from la5nta/wl2k-go's fbb package (MIT, Martin Hebnes Pedersen).

import CryptoKit
import Foundation

public enum ProposalAnswer: UInt8, Sendable {
    case accept = 43 // '+'
    case reject = 45 // '-'
    case `defer` = 61 // '='
}

public struct Proposal: Sendable {
    public var code: UInt8 = UInt8(ascii: "C")
    public var msgType = "EM"
    public var mid: String
    public var title: String
    public var size: Int
    public var compressedSize: Int
    public var compressedData: [UInt8] = []
    public var answer: ProposalAnswer?
    public var offset = 0

    /// An outbound proposal: `data` is the message in wire format.
    public init(mid: String, title: String, data: [UInt8]) {
        self.mid = mid
        self.title = title.isEmpty ? "No title" : title
        size = data.count
        compressedData = LZHUF.compress(data)
        compressedSize = compressedData.count
    }

    public init(message: Message) throws {
        try message.validate()
        self.init(mid: message.mid, title: message.subject, data: try message.bytes())
    }

    init(code: UInt8, msgType: String, mid: String, size: Int, compressedSize: Int) {
        self.code = code
        self.msgType = msgType
        self.mid = mid
        self.title = ""
        self.size = size
        self.compressedSize = compressedSize
    }

    /// Parses "FC EM TJKYEIMMHSRB 527 123 0".
    static func parse(_ line: String) throws -> Proposal {
        let b = Array(line.utf8)
        guard b.count >= 4, b[0] == UInt8(ascii: "F") else { throw B2FError.protocolError("Unexpected end of proposal line") }
        let code = b[1]
        guard code == UInt8(ascii: "C") || code == UInt8(ascii: "D") || code == UInt8(ascii: "A") || code == UInt8(ascii: "B") else {
            throw B2FError.protocolError("Unsupported proposal code '\(Character(UnicodeScalar(code)))'")
        }
        let parts = String(decoding: b[3...], as: UTF8.self).split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if code == UInt8(ascii: "A") || code == UInt8(ascii: "B") {
            // Not supported; keep enough to defer it.
            return Proposal(code: code, msgType: parts.first ?? "", mid: parts.count > 1 ? parts[1] : "", size: 0, compressedSize: 0)
        }
        guard parts.count >= 5 else { throw B2FError.protocolError("Malformed proposal: \(line)") }
        guard parts.count == 5 else { throw B2FError.protocolError("Too many parts in proposal: \(line)") }
        guard parts[0] == "EM" || parts[0] == "CM" else {
            throw B2FError.protocolError("Expected message type CM or EM, but found \(parts[0])")
        }
        return Proposal(code: code, msgType: parts[0], mid: parts[1], size: Int(parts[2]) ?? 0, compressedSize: Int(parts[3]) ?? 0)
    }

    var line: String { "F\(Character(UnicodeScalar(code))) \(msgType) \(mid) \(size) \(compressedSize) 0" }

    /// Lower is more urgent (winlink.org message precedence).
    var precedence: Int {
        if title.contains("//WL2K Z/") { return 0 }
        if title.contains("//WL2K O/") { return 1 }
        if title.contains("//WL2K P/") { return 2 }
        return 3
    }

    /// The decompressed message bytes.
    public func data() throws -> [UInt8] {
        guard code == UInt8(ascii: "C") else { throw B2FError.protocolError("unsupported compression \(Character(UnicodeScalar(code)))") }
        return try LZHUF.decompress(compressedData)
    }

    public func message() throws -> Message { try Message(parsing: data()) }

    /// Ascending size, then stable by precedence (as wl2k-go sorts outbound proposals).
    static func sorted(_ props: [Proposal]) -> [Proposal] {
        let bySize = props.sorted { a, b in
            a.compressedSize != b.compressedSize ? a.compressedSize < b.compressedSize : a.mid < b.mid
        }
        return bySize.enumerated().sorted { a, b in
            a.element.precedence != b.element.precedence ? a.element.precedence < b.element.precedence : a.offset < b.offset
        }.map(\.element)
    }

    /// Applies an "FS ..." answer line to `props`, in order.
    static func applyAnswer(_ line: String, to props: inout [Proposal]) throws {
        var s: [UInt8] = line.hasPrefix("FS ") ? Array(line.utf8.dropFirst(3)) : Array(line.utf8)
        var i = 0
        while !s.isEmpty {
            guard i < props.count else { throw B2FError.protocolError("Got answer for more proposals than expected") }
            let c = s.removeFirst()
            switch c {
            case UInt8(ascii: "Y"), UInt8(ascii: "y"), UInt8(ascii: "+"):
                props[i].answer = .accept
            case UInt8(ascii: "N"), UInt8(ascii: "n"), UInt8(ascii: "R"), UInt8(ascii: "r"), UInt8(ascii: "-"):
                props[i].answer = .reject
            case UInt8(ascii: "L"), UInt8(ascii: "l"), UInt8(ascii: "="), UInt8(ascii: "H"), UInt8(ascii: "h"):
                props[i].answer = .defer
            case UInt8(ascii: "A"), UInt8(ascii: "a"), UInt8(ascii: "!"):
                let digits = s.prefix { $0 >= 0x30 && $0 <= 0x39 }
                guard !digits.isEmpty else { throw B2FError.protocolError("Got offset request without offset index") }
                s.removeFirst(digits.count)
                props[i].answer = .accept
                let offset = Int(String(decoding: digits, as: UTF8.self)) ?? 0
                // The binary protocol cannot express offsets over 6 digits.
                props[i].offset = offset > 999_999 || offset > props[i].compressedData.count ? 0 : offset
            default:
                throw B2FError.protocolError("Invalid character (\(Character(UnicodeScalar(c)))) in proposal answer line")
            }
            i += 1
        }
    }
}

/// The Winlink secure login response to a ";PQ: <challenge>" line.
///
/// Ported from wl2k-go (which took it from paclink-unix).
public enum SecureLogin {
    static let salt: [UInt8] = [
        77, 197, 101, 206, 190, 249, 93, 200, 51, 243, 93, 237, 71, 94, 239, 138, 68, 108, 70, 185, 225, 137, 217, 16,
        51, 122, 193, 48, 194, 195, 198, 175, 172, 169, 70, 84, 61, 62, 104, 186, 114, 52, 61, 168, 66, 129, 192, 208,
        187, 249, 232, 193, 41, 113, 41, 45, 240, 16, 29, 228, 208, 228, 61, 20,
    ]

    public static func response(challenge: String, password: String) -> String {
        let payload = Array(challenge.utf8) + Array(password.utf8) + salt
        let sum = Array(Insecure.MD5.hash(data: Data(payload)))
        var pr = Int32(sum[3] & 0x3f)
        for i in stride(from: 2, through: 0, by: -1) {
            pr = (pr << 8) | Int32(sum[i])
        }
        let s = String(format: "%08d", pr)
        return String(s.suffix(8))
    }
}
