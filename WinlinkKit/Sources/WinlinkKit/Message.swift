// The Winlink message structure (winlink.org/B2F): a MIME-like header block,
// a body, and attachments, each section followed by CRLF.
//
// Ported from la5nta/wl2k-go's fbb package (MIT, Martin Hebnes Pedersen).

import CryptoKit
import Foundation

public struct Address: Hashable, Codable, CustomStringConvertible, Sendable {
    public var proto: String
    public var addr: String

    public init(proto: String = "", addr: String) {
        self.proto = proto
        self.addr = addr
    }

    /// Parses N0CALL, N0CALL@winlink.org, foo@bar.baz (SMTP) or PROTO:addr.
    public init(_ s: String) {
        let colon = s.split(separator: ":", omittingEmptySubsequences: false)
        let at = s.split(separator: "@", omittingEmptySubsequences: false)
        if colon.count == 2 {
            self.init(proto: String(colon[0]), addr: String(colon[1]))
        } else if at.count == 1 {
            self.init(addr: s)
        } else if at[1].lowercased() == "winlink.org" {
            self.init(addr: String(at[0]))
        } else {
            self.init(proto: "SMTP", addr: s)
        }
        if proto.isEmpty { addr = addr.uppercased() }
    }

    public var description: String { proto.isEmpty ? addr : "\(proto):\(addr)" }
}

public enum MessageError: Error, Equatable, LocalizedError {
    case invalid(field: String, reason: String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(field, reason): return "\(field): \(reason)"
        case let .malformed(s): return "malformed message: \(s)"
        }
    }
}

public struct Attachment: Hashable, Codable, Sendable {
    public var name: String
    public var data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

public struct Message: Hashable, Sendable {
    /// Canonical header key → values, in insertion order per key.
    public private(set) var header: [String: [String]] = [:]
    public var body: [UInt8] = []
    public var files: [Attachment] = []

    public static let dateFormat = "yyyy/MM/dd HH:mm"
    public static let defaultCharset = "ISO-8859-1"

    public init() {}

    /// A new private message from `mycall` with a fresh MID and the current date.
    public init(from mycall: String, type: String = "Private", date: Date = Date()) {
        setField("Mid", Message.generateMID(mycall))
        self.date = date
        setField("From", Address(mycall).description)
        setField("Mbo", mycall)
        setField("Type", type)
    }

    // MARK: Header access

    public static func canonicalKey(_ k: String) -> String {
        var out = ""
        var upper = true
        for ch in k {
            out += upper ? ch.uppercased() : ch.lowercased()
            upper = ch == "-"
        }
        return out
    }

    public func field(_ key: String) -> String { header[Message.canonicalKey(key)]?.first ?? "" }
    public func values(_ key: String) -> [String] { header[Message.canonicalKey(key)] ?? [] }
    public mutating func setField(_ key: String, _ value: String) { header[Message.canonicalKey(key)] = [value] }
    public mutating func addField(_ key: String, _ value: String) { header[Message.canonicalKey(key), default: []].append(value) }
    public mutating func removeField(_ key: String) { header[Message.canonicalKey(key)] = nil }

    public var mid: String { field("Mid") }
    public var from: Address { Address(field("From")) }
    public var to: [Address] { values("To").map(Address.init) }
    public var cc: [Address] { values("Cc").map(Address.init) }
    public var receivers: [Address] { to + cc }
    public var type: String { field("Type") }

    public var subject: String {
        get { MIMEWords.decode(field("Subject")) }
        set { setField("Subject", MIMEWords.encode(newValue)) }
    }

    public var date: Date? {
        get { Message.parseDate(field("Date")) }
        set { if let d = newValue { setField("Date", Message.formatDate(d)) } }
    }

    public mutating func addTo(_ addrs: String...) { for a in addrs { addField("To", Address(a).description) } }
    public mutating func addCc(_ addrs: String...) { for a in addrs { addField("Cc", Address(a).description) } }
    public mutating func addTo(_ addrs: [String]) { for a in addrs { addField("To", Address(a).description) } }
    public mutating func addCc(_ addrs: [String]) { for a in addrs { addField("Cc", Address(a).description) } }

    // MARK: Body

    /// Sets the body: CRLF line endings, lines wrapped at 998 bytes, ISO-8859-1 when it fits, else UTF-8.
    public mutating func setBody(_ text: String) {
        let charset = text.canBeConverted(to: .isoLatin1) ? Message.defaultCharset : "UTF-8"
        setField("Content-Transfer-Encoding", "8bit")
        setField("Content-Type", "text/plain; charset=\(charset)")
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var out: [UInt8] = []
        for line in lines {
            var bytes = Message.encode(line, charset: charset)
            repeat {
                let n = min(bytes.count, 998)
                out += bytes[..<n]
                out += [13, 10]
                bytes.removeFirst(n)
            } while !bytes.isEmpty
        }
        body = out
        setField("Body", String(body.count))
    }

    public var bodySize: Int { Int(field("Body")) ?? 0 }

    public var charset: String {
        let ct = field("Content-Type")
        for part in ct.split(separator: ";").dropFirst() {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "charset" {
                return kv[1].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            }
        }
        return Message.defaultCharset
    }

    public var bodyText: String { Message.decode(body, charset: charset) }

    public mutating func addFile(_ file: Attachment) {
        files.append(file)
        addField("File", "\(file.data.count) \(MIMEWords.encode(file.name))")
    }

    // MARK: Validation & serialisation

    public func validate() throws {
        if mid.isEmpty { throw MessageError.invalid(field: "MID", reason: "Empty MID") }
        if mid.count > 12 { throw MessageError.invalid(field: "MID", reason: "MID too long") }
        if receivers.isEmpty { throw MessageError.invalid(field: "To/Cc", reason: "No recipient") }
        if field("From").isEmpty { throw MessageError.invalid(field: "From", reason: "Empty From field") }
        if bodySize == 0 { throw MessageError.invalid(field: "Body", reason: "Empty body") }
        if field("Subject").isEmpty { throw MessageError.invalid(field: "Subject", reason: "Empty subject") }
        if field("Subject").count > 128 { throw MessageError.invalid(field: "Subject", reason: "Subject too long") }
        for f in files where f.name.utf8.count > 255 {
            throw MessageError.invalid(field: "Files", reason: "Attachment file name too long: \(f.name)")
        }
    }

    /// The message in Winlink wire format: Mid first, then the other header keys sorted.
    public func bytes() throws -> [UInt8] {
        if Message.parseDate(field("Date")) == nil && !field("Date").isEmpty {
            throw MessageError.malformed("bad Date header")
        }
        guard !mid.isEmpty else { throw MessageError.malformed("missing MID in header") }
        var s = "Mid: \(mid)\r\n"
        for key in header.keys.filter({ $0 != "Mid" }).sorted() {
            for v in header[key]! {
                s += "\(key): \(v.trimmingCharacters(in: .whitespaces))\r\n"
            }
        }
        s += "\r\n"
        // Header values are ASCII (encoded words), so UTF-8 is exact.
        var out = Array(s.utf8)
        out += body
        if !files.isEmpty { out += [13, 10] }
        for f in files {
            out += f.data
            out += [13, 10]
        }
        return out
    }

    /// Parses a message in Winlink wire format.
    public init(parsing data: [UInt8]) throws {
        var i = 0
        while i < data.count, [9, 10, 11, 12, 13, 32].contains(data[i]) { i += 1 }
        var sawHeader = false
        var last: String?
        while true {
            guard let nl = data[i...].firstIndex(of: 10) else { throw MessageError.malformed("unterminated header") }
            var line = data[i..<nl]
            if line.last == 13 { line = line.dropLast() }
            i = nl + 1
            if line.isEmpty { break }
            // Header lines should be ASCII, but some gateways pass raw ISO-8859-1 through.
            let text = String(bytes: line, encoding: .utf8) ?? String(bytes: line, encoding: .isoLatin1) ?? ""
            if (line.first == 32 || line.first == 9), let k = last {
                // Folded continuation line.
                var vs = header[k]!
                vs[vs.count - 1] += " " + text.trimmingCharacters(in: .whitespaces)
                header[k] = vs
                continue
            }
            guard let colon = text.firstIndex(of: ":") else { throw MessageError.malformed("bad header line: \(text)") }
            let key = Message.canonicalKey(String(text[..<colon]).trimmingCharacters(in: .whitespaces))
            let value = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            header[key, default: []].append(value)
            last = key
            sawHeader = true
        }
        guard sawHeader else { throw MessageError.malformed("no header") }

        func section(_ n: Int) throws -> [UInt8] {
            guard i + n <= data.count else { throw MessageError.malformed("section shorter than declared") }
            let s = Array(data[i..<(i + n)])
            i += n
            if i < data.count {
                guard data.count - i >= 2, data[i] == 13, data[i + 1] == 10 else {
                    throw MessageError.malformed("unexpected end of section")
                }
                i += 2
            }
            return s
        }

        body = try section(bodySize)
        for value in values("File") {
            let parts = value.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let size = Int(parts[0]) else { throw MessageError.malformed("bad File header: \(value)") }
            files.append(Attachment(name: MIMEWords.decode(String(parts[1])), data: Data(try section(size))))
        }
        if !field("Date").isEmpty && Message.parseDate(field("Date")) == nil {
            throw MessageError.malformed("unparseable Date: \(field("Date"))")
        }
    }

    // MARK: Helpers

    static func encode(_ s: String, charset: String) -> [UInt8] {
        if charset.uppercased() == "UTF-8" { return Array(s.utf8) }
        return Array(s.data(using: .isoLatin1, allowLossyConversion: true) ?? Data(s.utf8))
    }

    static func decode(_ b: [UInt8], charset: String) -> String {
        switch charset.uppercased() {
        case "UTF-8", "UTF8", "US-ASCII", "ASCII":
            return String(decoding: b, as: UTF8.self)
        default:
            return String(data: Data(b), encoding: .isoLatin1) ?? String(decoding: b, as: UTF8.self)
        }
    }

    /// A 12 character MID: base32 of an MD5 over the call sign, time and some randomness.
    public static func generateMID(_ callsign: String) -> String {
        let payload = "\(Date().timeIntervalSince1970)-\(UUID().uuidString)-\(callsign)"
        let sum = Insecure.MD5.hash(data: Data(payload.utf8))
        return String(base32(Array(sum)).prefix(12))
    }

    static func base32(_ b: [UInt8]) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out = ""
        var acc = 0
        var bits = 0
        for byte in b {
            acc = (acc << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(acc >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(acc << (5 - bits)) & 31]) }
        return out
    }

    private static let utcFormatters: [DateFormatter] = {
        let layouts = [
            "yyyy/MM/dd HH:mm", "yyyy.MM.dd HH:mm", "yyyy-MM-dd HH:mm", "yyyyMMddHHmmss",
            "EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z",
        ]
        return layouts.map {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = $0
            return f
        }
    }()

    public static func formatDate(_ d: Date) -> String { utcFormatters[0].string(from: d) }

    public static func parseDate(_ s: String) -> Date? {
        if s.isEmpty { return nil }
        // Drop a trailing comment such as "(UTC)".
        let trimmed = s.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
        for f in utcFormatters {
            if let d = f.date(from: trimmed) { return d }
        }
        return nil
    }
}

/// RFC 2047 encoded words, as used for Subject and File headers.
public enum MIMEWords {
    /// Q-encodes `s` if it holds anything but printable ASCII (ISO-8859-1 when it fits, else UTF-8).
    public static func encode(_ s: String) -> String {
        if s.unicodeScalars.allSatisfy({ ($0.value >= 0x20 && $0.value <= 0x7e) || $0 == "\t" }) { return s }
        let latin = s.canBeConverted(to: .isoLatin1)
        let charset = latin ? "ISO-8859-1" : "UTF-8"
        let bytes = Message.encode(s, charset: charset)
        let prefix = "=?\(charset)?q?"
        let maxEncoded = 75 - prefix.count - 2
        var words: [String] = []
        var cur = ""
        // Keep multi-byte UTF-8 sequences inside one word.
        var i = 0
        while i < bytes.count {
            var n = 1
            if !latin && bytes[i] >= 0xC0 {
                n = bytes[i] >= 0xF0 ? 4 : bytes[i] >= 0xE0 ? 3 : 2
            }
            var piece = ""
            for b in bytes[i..<min(i + n, bytes.count)] {
                switch b {
                case 0x20: piece += "_"
                case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x21, 0x2A, 0x2B, 0x2D, 0x2F:
                    piece += String(UnicodeScalar(b))
                default: piece += String(format: "=%02X", b)
                }
            }
            if cur.count + piece.count > maxEncoded {
                words.append(prefix + cur + "?=")
                cur = ""
            }
            cur += piece
            i += n
        }
        if !cur.isEmpty || words.isEmpty { words.append(prefix + cur + "?=") }
        return words.joined(separator: " ")
    }

    /// Decodes encoded words; text without them is taken as UTF-8, or ISO-8859-1 when it is not valid UTF-8.
    public static func decode(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        let pattern = #"=\?([^?]+)\?([QqBb])\?([^?]*)\?="#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        var prevWasWord = false
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let gap = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            // Whitespace between adjacent encoded words is dropped.
            if !(prevWasWord && gap.trimmingCharacters(in: .whitespaces).isEmpty) { out += gap }
            let charset = ns.substring(with: m.range(at: 1))
            let enc = ns.substring(with: m.range(at: 2)).uppercased()
            let text = ns.substring(with: m.range(at: 3))
            var bytes: [UInt8] = []
            if enc == "B" {
                bytes = Array(Data(base64Encoded: text) ?? Data(text.utf8))
            } else {
                let u = Array(text.utf8)
                var i = 0
                while i < u.count {
                    if u[i] == UInt8(ascii: "_") {
                        bytes.append(0x20)
                    } else if u[i] == UInt8(ascii: "="), i + 2 < u.count,
                              let v = UInt8(String(decoding: u[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                        bytes.append(v)
                        i += 2
                    } else {
                        bytes.append(u[i])
                    }
                    i += 1
                }
            }
            out += Message.decode(bytes, charset: charset)
            last = m.range.location + m.range.length
            prevWasWord = true
        }
        out += ns.substring(from: last)
        return out
    }
}
