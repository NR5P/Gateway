import XCTest
@testable import WinlinkKit

/// The CMS telnet login against a scripted server (the live CMS is not contacted).
final class TelnetTests: XCTestCase {
    func testLoginThenB2F() async throws {
        let (client, srv) = PipeStream.pair()
        let login = Task { try await CMSTelnet.login(client, mycall: "n0tst", log: { _ in }) }
        try await srv.write("Welcome to the Winlink CMS\r\nCallsign :")
        let rd = StreamReader(srv)
        let call = String(decoding: try await rd.read(until: 13), as: UTF8.self)
        XCTAssertEqual(call, "N0TST\r")
        // Password prompt and the start of the handshake arrive in one chunk.
        try await srv.write("Password :\r[WL2K-5.0-B2FWIHJM$]\r")
        let pw = String(decoding: try await rd.read(until: 13), as: UTF8.self)
        XCTAssertEqual(pw, "CMSTelnet\r")
        let rest = try await login.value
        XCTAssertEqual(String(decoding: rest, as: UTF8.self), "[WL2K-5.0-B2FWIHJM$]\r")

        // The leftover bytes feed the B2F session.
        let s = B2FSession(mycall: "N0TST", targetcall: CMSTelnet.targetCall, locator: "EM10", mailbox: nil)
        let done = Task { try await s.exchange(PrefixedStream(client, prefix: rest)) }
        try await srv.write("CMS >\r")
        var lines: [String] = []
        for _ in 0..<4 { lines.append(String(decoding: try await rd.read(until: 13), as: UTF8.self)) }
        XCTAssertEqual(lines.last, "FF\r")
        XCTAssertEqual(lines[2], "; WL2K DE N0TST (EM10)\r")
        try await srv.write("FQ\r")
        _ = try await done.value
    }

    func testClosedBeforePrompt() async throws {
        let (client, srv) = PipeStream.pair()
        let login = Task { try await CMSTelnet.login(client, mycall: "N0TST", log: { _ in }) }
        try await srv.write("Callsign :")
        await srv.close()
        do {
            _ = try await login.value
            XCTFail("login succeeded on a closed stream")
        } catch {}
    }
}
