// Most cases here are ported from la5nta/wl2k-go's fbb tests (MIT).

import XCTest
@testable import WinlinkKit

final class MemoryMailbox: Mailbox {
    var out: [Message]
    var inbox: [Message] = []
    var sent: [(String, Bool)] = []
    var deferred: [String] = []
    var answer: ProposalAnswer = .accept

    init(out: [Message] = []) { self.out = out }

    func outbound(for forwarders: [Address]) -> [Message] {
        let sentMIDs = Set(sent.map(\.0))
        return out.filter { !sentMIDs.contains($0.mid) }
    }

    func markSent(mid: String, rejected: Bool) { sent.append((mid, rejected)) }
    func markDeferred(mid: String) { deferred.append(mid) }
    func answer(for proposal: Proposal) -> ProposalAnswer {
        inbox.contains { $0.mid == proposal.mid } ? .reject : answer
    }
    func receive(_ message: Message) throws { inbox.append(message) }
}

/// Reads CR-terminated lines from the far end of a pipe.
final class LineReader {
    let r: StreamReader
    init(_ s: ByteStream) { r = StreamReader(s) }
    func line() async throws -> String { String(decoding: try await r.read(until: 13), as: UTF8.self) }
}

func makeMessage(from: String = "N0CALL", to: String = "LA5NTA", subject: String = "Hello", body: String = "Hello world") -> Message {
    var m = Message(from: from)
    m.addTo(to)
    m.subject = subject
    m.setBody(body)
    return m
}

final class B2FTests: XCTestCase {
    func testSecureLoginResponse() {
        XCTAssertEqual(SecureLogin.response(challenge: "23753528", password: "FOOBAR"), "72768415")
        XCTAssertEqual(SecureLogin.response(challenge: "23753528", password: "FooBar"), "95074758")
    }

    func testParseFW() throws {
        XCTAssertEqual(try B2FSession.parseFW(";FW: LA5NTA"), [Address("LA5NTA")])
        XCTAssertEqual(try B2FSession.parseFW(";FW: LE1OF LA5NTA"), [Address("LE1OF"), Address("LA5NTA")])
        XCTAssertEqual(try B2FSession.parseFW(";FW: la4tta"), [Address(addr: "LA4TTA")])
        XCTAssertEqual(try B2FSession.parseFW(";FW: LA4TTA|12345678"), [Address(addr: "LA4TTA")])
    }

    func testParsePM() {
        let pm = PendingMessage.parse(";PM: LA5NTA FOOBARBAZ 869 SERVICE@winlink.org Your new Winlink Account")
        XCTAssertEqual(pm, PendingMessage(mid: "FOOBARBAZ", to: Address("LA5NTA"), from: Address("SERVICE@winlink.org"),
                                          subject: "Your new Winlink Account", size: 869))
    }

    func testLoginFailure() {
        XCTAssertTrue(B2FError.remote("[1] Secure login failed - account password does not match. - Disconnecting (88.90.2.192)").isLoginFailure)
        XCTAssertFalse(B2FError.connectionLost.isLoginFailure)
    }

    func testParseProposalAnswer() throws {
        func five() -> [Proposal] { (0..<5).map { Proposal(mid: "M\($0)", title: "t", data: Array(repeating: 65, count: 5000)) } }
        var p = five()
        try Proposal.applyAnswer("FS YLA3350RH", to: &p)
        XCTAssertEqual(p.map(\.answer), [.accept, .defer, .accept, .reject, .defer])
        XCTAssertEqual(p[2].offset, 3350 < p[2].compressedData.count ? 3350 : 0)
        p = five()
        try Proposal.applyAnswer("FS +=!3350-+", to: &p)
        XCTAssertEqual(p.map(\.answer), [.accept, .defer, .accept, .reject, .accept])
        XCTAssertThrowsError(try Proposal.applyAnswer("FS ++++++", to: &p))
        XCTAssertThrowsError(try Proposal.applyAnswer("FS X", to: &p))
    }

    func testParseProposal() throws {
        let p = try Proposal.parse("FC EM TJKYEIMMHSRB 527 123 0")
        XCTAssertEqual(p.mid, "TJKYEIMMHSRB")
        XCTAssertEqual(p.size, 527)
        XCTAssertEqual(p.compressedSize, 123)
        XCTAssertThrowsError(try Proposal.parse("FC XX TJKYEIMMHSRB 527 123 0"))
        XCTAssertThrowsError(try Proposal.parse("FC EM TJK 527"))
    }

    func testSortProposals() {
        func p(_ subject: String) -> Proposal { try! Proposal(message: makeMessage(subject: subject, body: "Satisfies validation")) }
        let sorted = Proposal.sorted([
            p("Just a test"), p("Re://WL2K O/Very important"), p("//WL2K R/Read this sometime, or don't"),
            p("//WL2K P/ Pretty important"), p("//WL2K Z/The world is on fire!"),
        ])
        XCTAssertEqual(sorted.map(\.title), [
            "//WL2K Z/The world is on fire!", "Re://WL2K O/Very important", "//WL2K P/ Pretty important",
            "Just a test", "//WL2K R/Read this sometime, or don't",
        ])
    }

    // MARK: Sessions against a scripted CMS

    func testSessionCMS() async throws {
        let (client, srv) = PipeStream.pair()
        let s = B2FSession(mycall: "LA5NTA", targetcall: "LA1B-10", locator: "JO39EQ", mailbox: nil)
        s.userAgent = .init(name: "wl2kgo", version: "0.1a")
        let done = Task { try await s.exchange(client) }

        try await srv.write("[WL2K-2.8.4.8-B2FWIHJM$]\rFoobar should be ignored\rTest CMS >\r")
        let rd = LineReader(srv)
        for want in [";FW: LA5NTA\r", "[wl2kgo-0.1a-B2FHM$]\r", "; LA1B-10 DE LA5NTA (JO39EQ)\r", "FF\r"] {
            let got = try await rd.line()
            XCTAssertEqual(got, want)
        }
        try await srv.write("FQ\r")
        _ = try await done.value
    }

    func testSessionCMSWithMessageDeferred() async throws {
        let (client, srv) = PipeStream.pair()
        let s = B2FSession(mycall: "LA5NTA", targetcall: "LA1B-10", locator: "JO39EQ", mailbox: nil)
        let done = Task { try await s.exchange(client) }
        try await srv.write("[WL2K-2.8.4.8-B2FWIHJM$]\rTest CMS >\r")
        let rd = LineReader(srv)
        for _ in 0..<4 { _ = try await rd.line() }
        try await srv.write("FC EM TJKYEIMMHSRB 527 123 0\rF> 3b\r")
        let answer = try await rd.line()
        XCTAssertEqual(answer, "FS =\r")
        // The CMS sends FQ and hangs up instead of waiting for our turn.
        try await srv.write("FQ\r")
        await srv.close()
        do {
            _ = try await done.value
        } catch B2FError.connectionLost {
            // Also fine: we may still have been writing FF when the CMS hung up.
        }
    }

    func testSessionCMSv4() async throws {
        let (client, srv) = PipeStream.pair()
        let s = B2FSession(mycall: "LA5NTA", targetcall: "LA1B-10", locator: "JO39EQ", mailbox: nil)
        let done = Task { try await s.exchange(client) }
        try await srv.write("[WL2K-4.0-B2FWIHJM$]\rTest CMS >\r")
        let rd = LineReader(srv)
        for _ in 0..<4 { _ = try await rd.line() }
        try await srv.write(";PM: LA5NTA TJKYEIMMHSRB 123 martin.h.pedersen@gmail.com\r;WARNING: Foo bar baz\r")
        try await srv.write("FC EM TJKYEIMMHSRB 527 123 0\rF> 3b\r")
        let a = try await rd.line()
        XCTAssertEqual(a, "FS =\r")
        let ff = try await rd.line()
        XCTAssertEqual(ff, "FF\r")
        try await srv.write(";WARNING: Foo bar baz\rFQ\r")
        _ = try await done.value
    }

    func testSecureLoginHandshake() async throws {
        let (client, srv) = PipeStream.pair()
        let s = B2FSession(mycall: "LA5NTA", targetcall: "WL2K", locator: "JO39EQ", mailbox: nil)
        s.password = { $0.addr == "LA5NTA" ? "FOOBAR" : nil }
        let done = Task { try await s.exchange(client) }
        try await srv.write("[WL2K-5.0-B2FWIHJM$]\r;PQ: 23753528\rCMS via LA1B >\r")
        let rd = LineReader(srv)
        var lines: [String] = []
        for _ in 0..<5 { lines.append(try await rd.line()) }
        XCTAssertEqual(lines[2], ";PR: 72768415\r")
        try await srv.write("FQ\r")
        _ = try await done.value
    }

    func testSecureLoginWithoutPasswordFails() async throws {
        let (client, srv) = PipeStream.pair()
        let s = B2FSession(mycall: "LA5NTA", targetcall: "WL2K", locator: "JO39EQ", mailbox: nil)
        let done = Task { try await s.exchange(client) }
        try await srv.write("[WL2K-5.0-B2FWIHJM$]\r;PQ: 23753528\rCMS >\r")
        do {
            _ = try await done.value
            XCTFail("expected passwordRequired")
        } catch {
            XCTAssertEqual(error as? B2FError, .passwordRequired)
        }
    }

    func testRemoteErrorLine() async throws {
        let (client, srv) = PipeStream.pair()
        let s = B2FSession(mycall: "LA5NTA", targetcall: "WL2K", locator: "JO39EQ", mailbox: MemoryMailbox(out: [makeMessage(from: "LA5NTA", to: "N0CALL")]))
        s.password = { _ in "WRONG" }
        let done = Task { try await s.exchange(client) }
        try await srv.write("[WL2K-5.0-B2FWIHJM$]\r;PQ: 23753528\rCMS >\r")
        try await srv.write("*** [1] Secure login failed - account password does not match. - Disconnecting\r")
        do {
            _ = try await done.value
            XCTFail("expected an error")
        } catch let e as B2FError {
            XCTAssertTrue(e.isLoginFailure, "\(e)")
        }
    }

    /// A gateway that sends one message and accepts one, checked byte by byte against what a CMS sends.
    func testScriptedGatewayExchange() async throws {
        let (client, srv) = PipeStream.pair()
        let outMsg = makeMessage(from: "N0CALL", to: "someone@example.com", subject: "Out", body: "Going out\nover the air")
        let box = MemoryMailbox(out: [outMsg])
        let s = B2FSession(mycall: "N0CALL", targetcall: "LA1B-10", locator: "JO39EQ", mailbox: box)
        let done = Task { try await s.exchange(client) }

        try await srv.write("[WL2K-5.0-B2FWIHJM$]\rTest CMS >\r")
        let rd = StreamReader(srv)
        func line() async throws -> String { String(decoding: try await rd.read(until: 13).dropLast(), as: UTF8.self) }
        for _ in 0..<3 { _ = try await line() }

        // Our proposal block.
        let prop = try await line()
        XCTAssertTrue(prop.hasPrefix("FC EM \(outMsg.mid) "), prop)
        let fsum = try await line()
        var sum = 0
        for c in (prop + "\r").utf8 { sum += Int(c) }
        XCTAssertEqual(fsum, String(format: "F> %02X", (-sum) & 0xff))
        try await srv.write("FS +\r")

        // The compressed message.
        let soh = try await rd.readByte()
        XCTAssertEqual(soh, 1)
        let hlen = Int(try await rd.readByte())
        let title = try await rd.read(until: 0)
        let off = try await rd.read(until: 0)
        XCTAssertEqual(hlen, title.count + off.count)
        XCTAssertEqual(String(decoding: title.dropLast(), as: UTF8.self), "Out")
        var data: [UInt8] = []
        var csum = 0
        while true {
            let b = try await rd.readByte()
            if b == 4 {
                csum += Int(try await rd.readByte())
                break
            }
            XCTAssertEqual(b, 2)
            let n = Int(try await rd.readByte())
            let chunk = try await rd.read(count: n)
            for c in chunk { csum += Int(c) }
            data += chunk
        }
        XCTAssertEqual(csum & 0xff, 0)
        let got = try Message(parsing: LZHUF.decompress(data))
        XCTAssertEqual(got.mid, outMsg.mid)
        XCTAssertEqual(got.bodyText, "Going out\r\nover the air\r\n")

        // Our turn ends; the gateway proposes one message for us.
        var inMsg = makeMessage(from: "SERVICE", to: "N0CALL", subject: "Welcome ÆØÅ", body: "Inbound body")
        inMsg.addFile(Attachment(name: "a.txt", data: Data("attached".utf8)))
        let p = try Proposal(message: inMsg)
        var psum = 0
        for c in (p.line + "\r").utf8 { psum += Int(c) }
        try await srv.write(p.line + "\r" + String(format: "F> %02X\r", (-psum) & 0xff))
        let fs = try await line()
        XCTAssertEqual(fs, "FS +")
        var blk: [UInt8] = [1, UInt8("Welcome".utf8.count + 3)] + Array("Welcome".utf8) + [0, 0x30, 0]
        var dsum = 0
        blk += [2, UInt8(p.compressedData.count)] + p.compressedData
        for b in p.compressedData { dsum += Int(b) }
        blk += [4, UInt8((-dsum) & 0xff)]
        try await srv.write(blk)
        let ff = try await line()
        XCTAssertEqual(ff, "FF")
        try await srv.write("FQ\r")
        let stats = try await done.value

        XCTAssertEqual(stats.sent, [outMsg.mid])
        XCTAssertEqual(stats.received, [inMsg.mid])
        XCTAssertEqual(box.inbox.first?.subject, "Welcome ÆØÅ")
        XCTAssertEqual(box.inbox.first?.files.first?.data, Data("attached".utf8))
        XCTAssertEqual(box.sent.map(\.0), [outMsg.mid])
    }

    /// Two of our own sessions, one as master, swap messages both ways (P2P).
    func testP2PBothWays() async throws {
        let (a, b) = PipeStream.pair()
        let boxA = MemoryMailbox(out: [makeMessage(from: "LA5NTA", to: "N0CALL", subject: "A to B", body: String(repeating: "abc ", count: 500))])
        let boxB = MemoryMailbox(out: [makeMessage(from: "N0CALL", to: "LA5NTA", subject: "B to A", body: "short")])
        let sa = B2FSession(mycall: "LA5NTA", targetcall: "N0CALL", locator: "JO39EQ", mailbox: boxA)
        let sb = B2FSession(mycall: "N0CALL", targetcall: "LA5NTA", locator: "JO39EQ", mailbox: boxB)
        sb.isMaster = true
        async let ra = sa.exchange(a)
        async let rb = sb.exchange(b)
        let (statsA, statsB) = try await (ra, rb)
        XCTAssertEqual(statsA.sent.count, 1)
        XCTAssertEqual(statsB.sent.count, 1)
        XCTAssertEqual(boxA.inbox.map(\.subject), ["B to A"])
        XCTAssertEqual(boxB.inbox.map(\.subject), ["A to B"])
        // 2000 bytes wrap into 998 + 998 + 4 byte lines.
        XCTAssertEqual(boxB.inbox.first?.body.count, 2000 + 3 * 2)
    }
}

final class MessageTests: XCTestCase {
    func testRoundTripWithWhitespaceBeforeHeader() throws {
        var m1 = Message(from: "LA5NTA")
        m1.addTo("N0CALL")
        m1.setBody("Hello world")
        let bytes = Array("\r\n\r\n\t ".utf8) + (try m1.bytes())
        let m2 = try Message(parsing: bytes)
        XCTAssertEqual(m1.header, m2.header)
        XCTAssertEqual(m2.bodyText, "Hello world\r\n")
    }

    func testEmptyMessageErrors() {
        XCTAssertThrowsError(try Message(parsing: []))
        XCTAssertThrowsError(try Message(parsing: Array("\r\n\r\nfoobar".utf8)))
    }

    func testWireFormat() throws {
        var m = Message()
        m.setField("Mid", "ABCDEFGHIJKL")
        m.setField("Date", "2016/12/30 01:00")
        m.setField("From", "LA5NTA")
        m.setField("Mbo", "LA5NTA")
        m.setField("Type", "Private")
        m.addTo("N0CALL", "foo@bar.baz")
        m.subject = "Test"
        m.setBody("Line 1\nLine 2")
        let text = String(decoding: try m.bytes(), as: UTF8.self)
        XCTAssertEqual(text, """
        Mid: ABCDEFGHIJKL\r
        Body: 16\r
        Content-Transfer-Encoding: 8bit\r
        Content-Type: text/plain; charset=ISO-8859-1\r
        Date: 2016/12/30 01:00\r
        From: LA5NTA\r
        Mbo: LA5NTA\r
        Subject: Test\r
        To: N0CALL\r
        To: SMTP:foo@bar.baz\r
        Type: Private\r
        \r
        Line 1\r
        Line 2\r

        """)
    }

    func testParseDate() {
        let want = Date(timeIntervalSince1970: 1_483_059_600) // 2016-12-30 01:00 UTC
        for s in ["2016/12/30 01:00", "2016.12.30 01:00", "2016-12-30 01:00", "20161230010000",
                  "Fri, 30 Dec 2016 01:00:00 -0000", "Fri, 30 Dec 2016 01:00:00 GMT"] {
            XCTAssertEqual(Message.parseDate(s), want, s)
        }
    }

    func testAddressFromString() {
        XCTAssertEqual(Address("LA5NTA"), Address(addr: "LA5NTA"))
        XCTAssertEqual(Address("la5nta"), Address(addr: "LA5NTA"))
        XCTAssertEqual(Address("LA5NTA@winlink.org"), Address(addr: "LA5NTA"))
        XCTAssertEqual(Address("la5nta@WINLINK.org"), Address(addr: "LA5NTA"))
        XCTAssertEqual(Address("foo@bar.baz"), Address(proto: "SMTP", addr: "foo@bar.baz"))
        XCTAssertEqual(Address("foo@bar.baz").description, "SMTP:foo@bar.baz")
    }

    func testEncodedWords() {
        let enc = MIMEWords.encode("æøå.txt")
        XCTAssertTrue(enc.unicodeScalars.allSatisfy { $0.isASCII }, enc)
        XCTAssertEqual(MIMEWords.decode(enc), "æøå.txt")
        XCTAssertEqual(MIMEWords.decode("=?utf-8?q?=C3=A6=C3=B8=C3=A5.txt?="), "æøå.txt")
        XCTAssertEqual(MIMEWords.decode("=?UTF-8?B?w6bDuMOl?="), "æøå")
        XCTAssertEqual(MIMEWords.decode("=?ISO-8859-1?q?a?= =?ISO-8859-1?q?b?="), "ab")
        XCTAssertEqual(MIMEWords.encode("plain subject"), "plain subject")
        let long = String(repeating: "ø", count: 100) + " 📡"
        XCTAssertEqual(MIMEWords.decode(MIMEWords.encode(long)), long)
    }

    func testDecodeLatin1FileName() throws {
        var m = Message(from: "N0CALL")
        m.addTo("LA5NTA")
        m.setBody("x")
        m.addFile(Attachment(name: "æøå.txt", data: Data()))
        for header in [m.values("File")[0], "0 æøå.txt"] {
            var copy = m
            copy.removeField("File")
            copy.addField("File", header)
            let parsed = try Message(parsing: copy.bytes())
            XCTAssertEqual(parsed.files.first?.name, "æøå.txt")
        }
        // Raw ISO-8859-1 bytes in the header.
        var raw = try m.bytes()
        let enc = Array(m.values("File")[0].utf8)
        let at = try XCTUnwrap(raw.firstRange(of: enc))
        raw.replaceSubrange(at, with: Array("0 ".utf8) + [0xE6, 0xF8, 0xE5] + Array(".txt".utf8))
        XCTAssertEqual(try Message(parsing: raw).files.first?.name, "æøå.txt")
    }

    func testUTF8BodyWhenLatin1CannotHoldIt() throws {
        var m = makeMessage(body: "73 de 📡")
        m.setBody("73 de 📡")
        XCTAssertEqual(m.charset, "UTF-8")
        XCTAssertEqual(try Message(parsing: m.bytes()).bodyText, "73 de 📡\r\n")
    }

    func testValidation() {
        var m = Message(from: "N0CALL")
        XCTAssertThrowsError(try m.validate())
        m.addTo("LA5NTA")
        m.subject = "s"
        m.setBody("b")
        XCTAssertNoThrow(try m.validate())
        XCTAssertEqual(m.mid.count, 12)
    }
}
