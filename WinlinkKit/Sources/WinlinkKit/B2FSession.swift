// A B2F (FBB B2 forwarding protocol with Winlink extensions) exchange.
//
// Ported from la5nta/wl2k-go's fbb package (MIT, Martin Hebnes Pedersen).
// Only B2 ("FC") proposals with LZHUF compression are supported, which is
// what the Winlink CMS, RMS gateways and Winlink Express use.

import Foundation

public enum B2FError: Error, Equatable, LocalizedError {
    case protocolError(String)
    case remote(String)
    case noB2Support
    case passwordRequired
    case connectionLost

    public var errorDescription: String? {
        switch self {
        case let .protocolError(s): return s
        case let .remote(s): return "remote: \(s)"
        case .noB2Support: return "Remote does not support B2 Forwarding Protocol"
        case .passwordRequired: return "The gateway asked for a secure login but no Winlink password is set"
        case .connectionLost: return "connection lost"
        }
    }

    /// True when the CMS rejected the secure login password.
    public var isLoginFailure: Bool {
        if case let .remote(s) = self { return s.lowercased().contains("secure login failed") }
        return false
    }
}

/// Where a session gets outbound messages and puts inbound ones.
public protocol Mailbox: AnyObject {
    /// Messages ready to send to the connected node. `forwarders` is empty when talking to the CMS/RMS.
    func outbound(for forwarders: [Address]) -> [Message]
    func markSent(mid: String, rejected: Bool)
    func markDeferred(mid: String)
    /// Accept unless the MID was already received.
    func answer(for proposal: Proposal) -> ProposalAnswer
    func receive(_ message: Message) throws
}

public struct PendingMessage: Equatable, Sendable {
    public var mid: String
    public var to: Address
    public var from: Address
    public var subject: String
    public var size: Int

    /// Parses ";PM: TO MID SIZE FROM SUBJECT".
    static func parse(_ line: String) -> PendingMessage? {
        var s = line
        if s.hasPrefix(";PM: ") { s.removeFirst(5) }
        let parts = s.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5 else { return nil }
        return PendingMessage(mid: parts[1], to: Address(parts[0]), from: Address(parts[3]), subject: parts[4], size: Int(parts[2]) ?? 0)
    }
}

public struct TrafficStats: Equatable, Sendable {
    public var received: [String] = []
    public var sent: [String] = []
}

public enum SessionEvent: Sendable {
    /// A protocol line, with the direction (">" sent, "<" received).
    case line(String, outbound: Bool)
    case info(String)
    case progress(mid: String, title: String, sending: Bool, done: Int, total: Int)
}

public final class B2FSession {
    public struct UserAgent: Sendable {
        public var name: String
        public var version: String
        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }
    }

    public let mycall: String
    public let targetcall: String
    public let locator: String
    public var isMaster = false
    public var motd: [String] = []
    /// Send ";FW:" in the handshake. A CMS-like master leaves it out, which tells the
    /// client it may hand over mail for anyone.
    public var announceForwarders = true
    public var userAgent = UserAgent(name: "Gateway", version: "1.0")
    /// The Winlink password for an address (the first is mycall). Nil means none known.
    public var password: (Address) -> String? = { _ in nil }
    public var onEvent: (SessionEvent) -> Void = { _ in }

    public private(set) var remoteSID = ""
    public private(set) var remoteForwarders: [Address] = []
    public private(set) var pendingMessages: [String: PendingMessage] = [:]
    public private(set) var stats = TrafficStats()

    private let mailbox: Mailbox?
    private var localForwarders: [Address]
    private var quitReceived = false
    private var quitSent = false
    private var remoteNoMsgs = false
    private var rd: StreamReader!
    private var conn: ByteStream!

    static let localSID = "B2FHM$"
    /// Paclink-unix uses 250; 125 keeps AX.25 paclen 128 links happy.
    static let maxBlockLength = 125
    static let maxProposals = 5

    public init(mycall: String, targetcall: String, locator: String, mailbox: Mailbox?, auxiliaryAddresses: [Address] = []) {
        self.mycall = mycall.uppercased()
        self.targetcall = targetcall.uppercased()
        self.locator = locator
        self.mailbox = mailbox
        localForwarders = [Address(mycall)] + auxiliaryAddresses
    }

    public var done: Bool { quitReceived || quitSent }

    /// Runs the whole exchange over `stream` and closes it.
    @discardableResult
    public func exchange(_ stream: ByteStream, prefix: [UInt8] = []) async throws -> TrafficStats {
        conn = stream
        rd = StreamReader(stream, prefix: prefix)
        do {
            try await handshake()
            var myTurn = !isMaster
            while !done {
                if myTurn {
                    quitSent = try await handleOutbound()
                } else {
                    quitReceived = try await handleInbound()
                }
                myTurn.toggle()
            }
            // Give the last FQ time to leave before hanging up.
            try? await stream.flush()
            await stream.close()
            return stats
        } catch {
            switch error {
            case StreamError.closed, B2FError.connectionLost:
                await stream.close()
                throw B2FError.connectionLost
            case B2FError.remote:
                await stream.close()
                throw error
            default:
                // Probably a protocol error: tell the remote, then hang up.
                try? await stream.write("*** \(error.localizedDescription)\r\n")
                try? await stream.flush()
                await stream.close()
                throw error
            }
        }
    }

    // MARK: Lines

    private func send(_ line: String) async throws {
        onEvent(.line(line, outbound: true))
        try await conn.write(line + "\r")
    }

    private func nextLine(parseErrors: Bool = true) async throws -> String {
        let raw = try await rd.read(until: 13)
        let line = B2FSession.clean(String(bytes: raw, encoding: .utf8) ?? String(bytes: raw, encoding: .isoLatin1) ?? "")
        onEvent(.line(line, outbound: false))
        if parseErrors, let err = B2FSession.errorLine(line) { throw B2FError.remote(err) }
        return line
    }

    static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("\0") { t.removeFirst() }
        while t.hasSuffix("\0") { t.removeLast() }
        return t
    }

    /// "*** some error" → "some error".
    static func errorLine(_ s: String) -> String? {
        guard s.hasPrefix("*"), let idx = s.lastIndex(of: "*") else { return nil }
        let rest = s[s.index(after: idx)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    // MARK: Handshake

    private func handshake() async throws {
        if isMaster {
            for l in motd { try await conn.write(l + "\r") }
            try await sendHandshake(challenge: nil)
        }
        var sid = ""
        var challenge: String?
        while true {
            let b = try await rd.peek()
            if b == UInt8(ascii: "F") && isMaster { break }
            // The CMS sends lines such as "*** MTD Stats ..." here that are not errors.
            let line = try await nextLine(parseErrors: false)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                guard let dash = line.lastIndex(of: "-") else { throw B2FError.protocolError("Bad SID line: \(line)") }
                sid = String(line[line.index(after: dash)..<line.index(before: line.endIndex)]).uppercased()
                guard sid.contains("B2") else { throw B2FError.noB2Support }
            } else if line.hasPrefix(";FW") {
                remoteForwarders = try B2FSession.parseFW(line)
            } else if line.hasPrefix(";PQ") {
                challenge = String(line.dropFirst(5))
            } else if line.hasSuffix(">") {
                break
            }
        }
        guard !sid.isEmpty else { throw B2FError.protocolError("No sid in handshake") }
        remoteSID = sid
        if !isMaster { try await sendHandshake(challenge: challenge) }
    }

    static func parseFW(_ line: String) throws -> [Address] {
        guard line.hasPrefix(";FW: ") else { throw B2FError.protocolError("Malformed forward line") }
        return line.dropFirst(5).split(separator: " ").map {
            Address(String($0.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)[0]))
        }
    }

    private func sendHandshake(challenge: String?) async throws {
        var out = ";FW:"
        for (i, addr) in localForwarders.enumerated() {
            if let c = challenge, i > 0, let pw = password(addr), !pw.isEmpty {
                // Winlink Express separates the aux address password hash with a pipe.
                out += " \(addr.addr)|\(SecureLogin.response(challenge: c, password: pw))"
            } else {
                out += " \(addr.addr)"
            }
        }
        var lines = announceForwarders ? [out] : []
        lines.append("[\(userAgent.name)-\(userAgent.version)-\(B2FSession.localSID)]")
        if let c = challenge {
            guard let pw = password(localForwarders[0]), !pw.isEmpty else { throw B2FError.passwordRequired }
            lines.append(";PR: \(SecureLogin.response(challenge: c, password: pw))")
        }
        lines.append("; \(targetcall) DE \(mycall) (\(locator))" + (isMaster ? ">" : ""))
        for l in lines { onEvent(.line(l, outbound: true)) }
        try await conn.write(lines.map { $0 + "\r" }.joined())
    }

    // MARK: Outbound

    private func outboundProposals() -> [Proposal] {
        guard let mb = mailbox else { return [] }
        var props: [Proposal] = []
        for m in mb.outbound(for: remoteForwarders) {
            do {
                props.append(try Proposal(message: m))
            } catch {
                onEvent(.info("Ignoring invalid outbound message \(m.mid): \(error.localizedDescription)"))
            }
        }
        return Proposal.sorted(props)
    }

    private func handleOutbound() async throws -> Bool {
        let outbound = outboundProposals()
        if outbound.isEmpty {
            try await send(remoteNoMsgs ? "FQ" : "FF")
            return remoteNoMsgs
        }
        var sent = try await sendOutbound(Array(outbound.prefix(B2FSession.maxProposals)))
        for (mid, rejected) in sent where rejected {
            mailbox?.markSent(mid: mid, rejected: true)
            sent[mid] = nil
        }
        // After a turnover only 'F' or ';' are valid; anything else (usually "***") is an error.
        let b = try await rd.peek()
        if b != UInt8(ascii: "F") && b != UInt8(ascii: ";") {
            let line = try await nextLine()
            throw B2FError.protocolError("Unexpected response: '\(line)'")
        }
        for (mid, rejected) in sent {
            mailbox?.markSent(mid: mid, rejected: rejected)
            stats.sent.append(mid)
        }
        return false
    }

    private func sendOutbound(_ block: [Proposal]) async throws -> [String: Bool] {
        var props = block
        var checksum = 0
        var lines: [String] = []
        for p in props {
            lines.append(p.line)
            for c in p.line.utf8 { checksum += Int(c) }
            checksum += 13
        }
        lines.append(String(format: "F> %02X", (-checksum) & 0xff))
        for l in lines { onEvent(.line(l, outbound: true)) }
        try await conn.write(lines.map { $0 + "\r" }.joined())

        var reply = ""
        while reply.isEmpty {
            let line = try await nextLine()
            if line.hasPrefix("FS ") {
                reply = line
            } else if line.hasPrefix(";PM") {
                if let pm = PendingMessage.parse(line) { pendingMessages[pm.mid] = pm }
            } else if line.hasPrefix(";") {
                continue
            } else {
                throw B2FError.protocolError("Expected proposal answer from remote. Got: \(line)")
            }
        }
        try Proposal.applyAnswer(reply, to: &props)

        var sent: [String: Bool] = [:]
        for p in props {
            switch p.answer {
            case .defer?, nil:
                mailbox?.markDeferred(mid: p.mid)
            case .reject?:
                sent[p.mid] = true
            case .accept?:
                try await writeCompressed(p)
                sent[p.mid] = false
            }
        }
        return sent
    }

    private func writeCompressed(_ p: Proposal) async throws {
        onEvent(.info("Transmitting [\(p.title)] [offset \(p.offset)]"))
        guard p.compressedSize >= 6 else { throw B2FError.protocolError("Invalid compressed data") }
        // The title must be ASCII and the header length must fit a byte.
        var title = MIMEWords.encode(String(p.title.prefix(80)))
        if title.utf8.count > 200 { title = String(title.prefix(200)) }
        let offset = String(p.offset)
        var out: [UInt8] = [1, UInt8(title.utf8.count + offset.utf8.count + 2)]
        out += Array(title.utf8) + [0] + Array(offset.utf8) + [0]

        let data = p.compressedData[p.offset...]
        var checksum = 0
        var i = data.startIndex
        var first = true
        while i < data.endIndex {
            let n = min(B2FSession.maxBlockLength, data.endIndex - i)
            var block: [UInt8] = first ? out : []
            first = false
            block += [2, UInt8(n)]
            for b in data[i..<(i + n)] {
                block.append(b)
                checksum += Int(b)
            }
            try await conn.write(block)
            i += n
            onEvent(.progress(mid: p.mid, title: p.title, sending: true, done: i - data.startIndex, total: data.count))
        }
        try await conn.write([4, UInt8((-checksum) & 0xff)])
        // Block until it has gone over the air.
        try await conn.flush()
    }

    // MARK: Inbound

    private func handleInbound() async throws -> Bool {
        var checksum = 0
        var proposals: [Proposal] = []
        var quit = false
        loop: while true {
            let line = try await nextLine()
            if line.hasPrefix(";PM") {
                if let pm = PendingMessage.parse(line) { pendingMessages[pm.mid] = pm }
                continue
            }
            if line.isEmpty || line.hasPrefix(";") { continue }
            guard line.count >= 2, line.hasPrefix("F") else {
                throw B2FError.protocolError("Got unexpected protocol line: '\(line)'")
            }
            switch String(line.prefix(2)) {
            case "FA", "FB", "FC", "FD":
                for c in line.utf8 { checksum += Int(c) }
                checksum += 13
                proposals.append(try Proposal.parse(line))
            case "FF":
                remoteNoMsgs = true
                break loop
            case "FQ":
                quit = true
                break loop
            case "F>":
                let theirs = Int(line.dropFirst(3).trimmingCharacters(in: .whitespaces), radix: 16) ?? -1
                let ours = (-checksum) & 0xff
                guard theirs == ours else { throw B2FError.protocolError("Checksum error (\(ours)-\(theirs))") }
                if proposals.isEmpty {
                    remoteNoMsgs = true
                    return false
                }
                remoteNoMsgs = false
                onEvent(.info("\(proposals.count) proposal(s) received"))
                try await answerProposals(&proposals)
                break loop
            default:
                throw B2FError.protocolError("Unknown protocol command \(line.dropFirst().prefix(1))")
            }
        }

        let accepted = proposals.filter { $0.answer == .accept }
        if quit && !accepted.isEmpty {
            throw B2FError.protocolError("Got quit command when inbound proposals were pending")
        }
        for var p in accepted {
            try await readCompressed(&p)
            let msg = try p.message()
            try mailbox?.receive(msg)
            stats.received.append(p.mid)
        }
        return quit
    }

    private func answerProposals(_ proposals: inout [Proposal]) async throws {
        var seen = Set<String>()
        for i in proposals.indices {
            let p = proposals[i]
            if seen.contains(p.mid) {
                // Radio-only gateways sometimes propose the same MID twice in a block.
                proposals[i].answer = .defer
            } else if p.code != UInt8(ascii: "C") {
                onEvent(.info("Deferring \(p.mid) (unsupported format)"))
                proposals[i].answer = .defer
            } else if let mb = mailbox {
                proposals[i].answer = mb.answer(for: p)
            } else {
                proposals[i].answer = .defer
            }
            seen.insert(p.mid)
        }
        let answers = String(decoding: proposals.map { $0.answer!.rawValue }, as: UTF8.self)
        try await send("FS \(answers)")
    }

    private func readCompressed(_ p: inout Proposal) async throws {
        let first = try await rd.readByte()
        switch first {
        case 1:
            break
        case UInt8(ascii: "*"):
            let line = try await nextLine(parseErrors: false)
            throw B2FError.remote("Got error from CMS: \(line)")
        default:
            throw B2FError.protocolError("First byte not as expected, got \(first)")
        }
        let headerLength = Int(try await rd.readByte())
        let rawTitle = Array(try await rd.read(until: 0).dropLast())
        let titleText = String(bytes: rawTitle, encoding: .utf8) ?? String(bytes: rawTitle, encoding: .isoLatin1) ?? ""
        p.title = MIMEWords.decode(titleText)
        let offsetBytes = Array(try await rd.read(until: 0).dropLast())
        guard headerLength == rawTitle.count + offsetBytes.count + 2 else {
            throw B2FError.protocolError("Header length mismatch: expected \(headerLength), got \(rawTitle.count + offsetBytes.count + 2)")
        }
        guard let offset = Int(String(decoding: offsetBytes, as: UTF8.self)) else {
            throw B2FError.protocolError("Offset header not parseable as integer")
        }
        guard offset == p.offset else { throw B2FError.protocolError("Expected offset \(p.offset), got \(offset)") }
        onEvent(.info("Receiving [\(p.title)] [offset \(p.offset)]"))

        var buf: [UInt8] = []
        var checksum = 0
        while true {
            let c = try await rd.readByte()
            switch c {
            case 2:
                var length = Int(try await rd.readByte())
                if length == 0 { length = 256 }
                let chunk = try await rd.read(count: length)
                for b in chunk { checksum = (checksum + Int(b)) % 256 }
                buf += chunk
                onEvent(.progress(mid: p.mid, title: p.title, sending: false, done: buf.count, total: p.compressedSize))
            case 4:
                checksum = (checksum + Int(try await rd.readByte())) % 256
                guard checksum == 0 else { throw B2FError.protocolError("Bad checksum") }
                guard buf.count == p.compressedSize else { throw B2FError.protocolError("Length mismatch after EOT") }
                p.compressedData = buf
                return
            default:
                throw B2FError.protocolError("Unexpected byte in compressed stream: \(c)")
            }
        }
    }
}
