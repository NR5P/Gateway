// A stand-in Winlink gateway for testing clients over a VARA modem.
//
//   swift run test-gateway [--call N1RMS] [--port 18600] [--password SECRET]
//
// It listens on the modem at 127.0.0.1:<port>, answers each call as B2F
// master, delivers one generated message addressed to the caller, and prints
// whatever the caller sends. With --password it issues a secure login
// challenge (;PQ) and checks the caller's ;PR answer like the CMS does.

import Foundation
import WinlinkKit

setvbuf(stdout, nil, _IOLBF, 0)

var call = "N1RMS"
var port: UInt16 = 18600
var password: String?
var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
    switch a {
    case "--call": call = args.popFirst()!.uppercased()
    case "--port": port = UInt16(args.popFirst()!)!
    case "--password": password = args.popFirst()
    default:
        FileHandle.standardError.write("unknown argument \(a)\n".data(using: .utf8)!)
        exit(2)
    }
}

final class GatewayMailbox: Mailbox {
    let caller: String
    var delivered = false
    init(caller: String) { self.caller = caller }

    func outbound(for forwarders: [Address]) -> [Message] {
        guard !delivered else { return [] }
        var m = Message(from: call)
        m.addTo(caller)
        m.subject = "Test message from \(call)"
        m.setBody("Hello \(caller),\n\nThis came over a VARA link from the test gateway at \(Message.formatDate(Date())) UTC.\n\n73")
        return [m]
    }

    func markSent(mid: String, rejected: Bool) {
        delivered = true
        print("gateway: delivered \(mid)\(rejected ? " (already had it)" : "")")
    }

    func markDeferred(mid: String) { print("gateway: \(mid) deferred") }
    func answer(for proposal: Proposal) -> ProposalAnswer { .accept }

    func receive(_ m: Message) throws {
        print("gateway: received \(m.mid) from \(m.from) to \(m.receivers.map(\.description).joined(separator: ", "))")
        print("  Subject: \(m.subject)")
        for l in m.bodyText.split(separator: "\r\n", omittingEmptySubsequences: false) { print("  | \(l)") }
        for f in m.files { print("  attachment \(f.name) (\(f.data.count) bytes)") }
    }
}

/// Wraps a link to inject a ;PQ challenge into the master's handshake and check the ;PR reply.
final class ChallengeCheck: ByteStream, @unchecked Sendable {
    let inner: ByteStream
    let challenge = String(format: "%08d", Int.random(in: 0..<100_000_000))
    let expect: String
    var injected = false
    var seen = ""
    var verdict: Bool?

    init(_ inner: ByteStream, password: String) {
        self.inner = inner
        expect = SecureLogin.response(challenge: challenge, password: password)
    }

    func read() async throws -> [UInt8] {
        let b = try await inner.read()
        if verdict == nil {
            seen += String(decoding: b, as: UTF8.self)
            if let r = seen.range(of: ";PR: ") {
                let got = String(seen[r.upperBound...].prefix(8))
                if got.count == 8 {
                    verdict = got == expect
                    print("gateway: secure login \(verdict! ? "ok" : "FAILED (got \(got), want \(expect))")")
                    if !verdict! {
                        try await inner.write("*** Secure login failed - account password does not match. - Disconnecting\r")
                        return []
                    }
                }
            }
        }
        return b
    }

    func write(_ bytes: [UInt8]) async throws {
        var out = bytes
        if !injected, let s = String(bytes: bytes, encoding: .utf8), let i = s.range(of: "]\r") {
            injected = true
            out = Array((s[..<i.upperBound] + ";PQ: \(challenge)\r" + s[i.upperBound...]).utf8)
        }
        try await inner.write(out)
    }

    func flush() async throws { try await inner.flush() }
    func close() async { await inner.close() }
}

let modem = VARAModem(config: VARAConfig(commandPort: port, mycall: call))
modem.onEvent = { e in
    if case let .line(l, out) = e, !l.hasPrefix("PTT"), !l.hasPrefix("BUFFER"), !l.hasPrefix("BITRATE"), l != "IAMALIVE" {
        print("modem \(out ? ">" : "<") \(l)")
    }
}

try await modem.open()
print("gateway: \(call) listening on \(modem.version) at 127.0.0.1:\(port)")
while true {
    do {
        let link = try await modem.accept()
        print("gateway: call from \(link.remote)")
        let stream: ByteStream = password.map { ChallengeCheck(link, password: $0) } ?? link
        let s = B2FSession(mycall: call, targetcall: link.remote, locator: "", mailbox: GatewayMailbox(caller: link.remote))
        s.isMaster = true
        s.announceForwarders = false
        s.userAgent = .init(name: "WL2K", version: "5.0")
        s.onEvent = { e in if case let .line(l, out) = e { print("b2f \(out ? ">" : "<") \(l)") } }
        let stats = try await s.exchange(stream)
        print("gateway: session done, \(stats.received.count) received, \(stats.sent.count) sent")
    } catch {
        print("gateway: session failed: \(error.localizedDescription)")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
}
