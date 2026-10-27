// Tests against live xara modems. Skipped unless the environment points at them:
//
//   XARA_CMD_PORT=18300     a running `xara` binary (no radio needed; see README)
//   XARA_AIRLINK=18500,18600  tools/xara-airlink: two xara modems linked by simulated audio

import XCTest
@testable import WinlinkKit

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [VARAEvent] = []
    func add(_ e: VARAEvent) { lock.withLock { items.append(e) } }
    var lines: [String] {
        lock.withLock {
            items.compactMap { if case let .line(l, outbound) = $0 { return (outbound ? "> " : "< ") + l } else { return nil } }
        }
    }
    var sawPTT: Bool { lock.withLock { items.contains { if case .ptt(true) = $0 { return true } else { return false } } } }
}

private func port(_ name: String) throws -> [UInt16] {
    guard let v = ProcessInfo.processInfo.environment[name] else { throw XCTSkip("set \(name) to run against xara") }
    return v.split(separator: ",").compactMap { UInt16($0) }
}

final class XaraIntegrationTests: XCTestCase {
    /// Setup commands, a CONNECT to a station that is not there, and ABORT, against the real xara binary.
    func testCommandProtocolAgainstXara() async throws {
        let p = try port("XARA_CMD_PORT")[0]
        let modem = VARAModem(config: VARAConfig(commandPort: p, mycall: "N0TST", mode: .hf, bandwidth: "2300"))
        let events = Collector()
        modem.onEvent = { events.add($0) }
        try await modem.open()
        XCTAssertTrue(modem.version.hasPrefix("VARA HF"), modem.version)
        XCTAssertEqual(modem.state, .idle)

        let call = Task { try await modem.connect(to: "N9ZZZ") }
        // The modem keys up to call; we see PTT ON and the state change.
        for _ in 0..<100 where !events.sawPTT { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(events.sawPTT, events.lines.joined(separator: "\n"))
        XCTAssertEqual(modem.state, .connecting("N9ZZZ"))
        call.cancel()
        do {
            _ = try await call.value
            XCTFail("connect to an absent station succeeded")
        } catch {}
        XCTAssertEqual(modem.state, .idle)
        let lines = events.lines
        for want in ["> VERSION", "> MYCALL N0TST", "> BW2300", "> CONNECT N0TST N9ZZZ", "> ABORT"] {
            XCTAssertTrue(lines.contains(want), "missing \(want) in\n\(lines.joined(separator: "\n"))")
        }
        XCTAssertFalse(lines.contains("< WRONG"), lines.joined(separator: "\n"))
        await modem.close()
        XCTAssertEqual(modem.state, .closed)
    }

    func testRefusedPort() async throws {
        _ = try port("XARA_CMD_PORT")
        let modem = VARAModem(config: VARAConfig(commandPort: 1, mycall: "N0TST"))
        do {
            try await modem.open()
            XCTFail("opened a closed port")
        } catch {}
    }

    /// A full B2F exchange over a VARA ARQ link between two xara modems: our client session
    /// calls a gateway (our session as master) and messages go both ways.
    func testB2FOverXaraAirlink() async throws {
        let ports = try port("XARA_AIRLINK")
        let gwBox = MemoryMailbox(out: [makeMessage(from: "N2TST", to: "N0TST", subject: "From the gateway", body: "Inbound over xara\n73")])
        var outMsg = makeMessage(from: "N0TST", to: "someone@example.com", subject: "From the phone", body: String(repeating: "Winlink over xara. ", count: 40))
        outMsg.addFile(Attachment(name: "note.txt", data: Data("attachment".utf8)))
        let clientBox = MemoryMailbox(out: [outMsg])

        let gwModem = VARAModem(config: VARAConfig(commandPort: ports[1], mycall: "N2TST"))
        let clModem = VARAModem(config: VARAConfig(commandPort: ports[0], mycall: "N0TST"))
        let clEvents = Collector()
        clModem.onEvent = { clEvents.add($0) }
        try await gwModem.open()
        try await clModem.open()

        let gateway = Task { () -> TrafficStats in
            let link = try await gwModem.accept(timeout: 120)
            let s = B2FSession(mycall: "N2TST", targetcall: link.remote, locator: "EM10", mailbox: gwBox)
            s.isMaster = true
            s.userAgent = .init(name: "TESTGW", version: "1.0")
            return try await s.exchange(link)
        }
        let link = try await clModem.connect(to: "N2TST")
        let client = B2FSession(mycall: "N0TST", targetcall: "N2TST", locator: "EM10", mailbox: clientBox)
        let clientStats = try await client.exchange(link)
        let gwStats = try await gateway.value

        XCTAssertEqual(clientStats.sent, [outMsg.mid])
        XCTAssertEqual(gwStats.received, [outMsg.mid])
        XCTAssertEqual(clientBox.inbox.map(\.subject), ["From the gateway"])
        XCTAssertEqual(clientBox.inbox.first?.bodyText, "Inbound over xara\r\n73\r\n")
        XCTAssertEqual(gwBox.inbox.first?.files.first?.data, Data("attachment".utf8))
        XCTAssertEqual(client.remoteSID, "B2FHM$")
        await clModem.close()
        await gwModem.close()
        print(clEvents.lines.filter { !$0.contains("PTT") && !$0.contains("BITRATE") && !$0.hasPrefix("< SN") }.joined(separator: "\n"))
    }
}
