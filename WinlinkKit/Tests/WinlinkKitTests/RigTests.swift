import XCTest
@testable import WinlinkKit

/// Rig control against scripted RigHelm and rigctld servers.
final class RigTests: XCTestCase {
    func testDialFrequency() {
        XCTAssertEqual(DialFrequency.parse("14105.0"), 14_105_000)
        XCTAssertEqual(DialFrequency.parse("14.105"), 14_105_000)
        XCTAssertEqual(DialFrequency.parse("7,101.5"), 7_101_500)
        XCTAssertEqual(DialFrequency.parse("145050000"), 145_050_000)
        XCTAssertNil(DialFrequency.parse("abc"))
        XCTAssertEqual(DialFrequency.format(14_105_000), "14.105.000")
    }

    func testRigHelmProof() {
        // Same construction as righelm's remote.rs (HMAC-SHA256, hex).
        XCTAssertEqual(RigHelmRig.proof(password: "", nonce: "ab", mode: "CAT"), "-")
        XCTAssertEqual(RigHelmRig.proof(password: "secret", nonce: "0011223344556677", mode: "CAT").count, 64)
    }

    func testBeacon() {
        let b = RigDiscovery.parseBeacon("FTDX3000-REMOTE v1;id=a1b2;name=Shack;port=4533;audio=1;auth=1;mic=0;radio=connected", from: "10.0.0.5")
        XCTAssertEqual(b?.0, "a1b2")
        XCTAssertEqual(b?.1, RigEndpoint(kind: .righelm, host: "10.0.0.5", port: 4533, name: "Shack", auth: true, radio: "connected"))
        XCTAssertNil(RigDiscovery.parseBeacon("hello", from: "10.0.0.5"))
    }

    /// A RigHelm station: login, then FTDX3000 CAT both ways.
    func testRigHelmSession() async throws {
        let (client, srv) = PipeStream.pair()
        let rd = StreamReader(srv)
        let open = Task { try await RigHelmRig.open(client, password: "pw") }
        try await srv.write("FTDX3000-REMOTE v1 00112233 Shack\n")
        let hello = String(decoding: try await rd.read(until: 10), as: UTF8.self)
        XCTAssertEqual(hello, "HELLO CAT \(RigHelmRig.proof(password: "pw", nonce: "00112233", mode: "CAT"))\n")
        try await srv.write("OK 00000000000000aa 4533 24000 ftdx3000\n")

        var radio = (fa: "FA07101500;", md: "MD02;", tx: "TX0;")
        // Answer what the client asks, like the radio.
        let answer = Task {
            while true {
                let f = String(decoding: try await rd.read(until: UInt8(ascii: ";")), as: UTF8.self)
                switch f {
                case "FA;": try await srv.write(radio.fa)
                case "MD0;": try await srv.write(radio.md)
                case "TX;": try await srv.write(radio.tx)
                case _ where f.hasPrefix("FA"): radio.fa = f
                case _ where f.hasPrefix("MD0"): radio.md = f
                case "TX1;": radio.tx = "TX2;"
                case "TX0;": radio.tx = "TX0;"
                default: break
                }
            }
        }
        defer { answer.cancel() }
        let rig = try await open.value
        XCTAssertEqual(rig.name, "RigHelm Shack: ftdx3000")
        var s = try await rig.status()
        XCTAssertEqual(s.frequency, 7_101_500)

        try await rig.setFrequency(14_105_000)
        try await rig.setMode(.dataUSB)
        s = try await rig.status()
        XCTAssertEqual(s.frequency, 14_105_000)
        XCTAssertEqual(s.mode, "DATA-U")

        try await rig.setPTT(true)
        try await Task.sleep(for: .milliseconds(200))
        s = try await rig.status()
        XCTAssertTrue(s.transmitting)
        // Closing while keyed un-keys first.
        await rig.close()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(radio.tx, "TX0;")
    }

    func testRigHelmDenied() async throws {
        let (client, srv) = PipeStream.pair()
        let open = Task { try await RigHelmRig.open(client, password: "bad") }
        try await srv.write("FTDX3000-REMOTE v1 00112233 Shack\n")
        _ = try await StreamReader(srv).read(until: 10)
        try await srv.write("DENIED wrong password\n")
        do {
            _ = try await open.value
            XCTFail("login succeeded")
        } catch let e as RigError {
            XCTAssertEqual(e, .denied("wrong password"))
        }
    }

    func testRigctld() async throws {
        let (client, srv) = PipeStream.pair()
        let rig = RigctldRig(stream: client, name: "rigctld test")
        let rd = StreamReader(srv)
        var sent: [String] = []
        let server = Task {
            var freq = "7101500", ptt = "0"
            while true {
                let l = String(decoding: try await rd.read(until: 10), as: UTF8.self).trimmingCharacters(in: .newlines)
                sent.append(l)
                switch l {
                case "f": try await srv.write("\(freq)\n")
                case "m": try await srv.write("PKTUSB\n3000\n")
                case "t": try await srv.write("\(ptt)\n")
                case "G TUNE": try await srv.write("RPRT -9\n")
                default:
                    if l.hasPrefix("F ") { freq = String(l.dropFirst(2)) }
                    if l.hasPrefix("T ") { ptt = String(l.dropFirst(2)) }
                    try await srv.write("RPRT 0\n")
                }
            }
        }
        defer { server.cancel() }
        // Requests from several tasks at once still pair with their answers.
        async let a: Void = rig.setFrequency(14_105_000)
        async let b = rig.status()
        _ = try await (a, b)
        try await rig.setMode(.dataUSB)
        try await rig.setPTT(true)
        let s = try await rig.status()
        XCTAssertEqual(s.frequency, 14_105_000)
        XCTAssertEqual(s.mode, "DATA-U")
        XCTAssertTrue(s.transmitting)
        do {
            try await rig.tune()
            XCTFail("tune accepted")
        } catch let e as RigError {
            XCTAssertEqual(e, .rejected(command: "G TUNE", code: -9))
        }
        await rig.close()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(sent.last, "T 0")
        XCTAssertTrue(sent.contains("M PKTUSB 0"))
    }
}
