import XCTest
@testable import WinlinkKit

/// Against a live rigctld, e.g. hamlib on RigHelm's simulator:
/// `righelm-sim` then `rigctld -m 1037 -r <sim pty> -t 14532`, and `RIGCTLD_PORT=14532 swift test`.
final class RigLiveTests: XCTestCase {
    func testLiveRigctld() async throws {
        guard let p = ProcessInfo.processInfo.environment["RIGCTLD_PORT"], let port = UInt16(p) else {
            throw XCTSkip("set RIGCTLD_PORT to run against a live rigctld")
        }
        let found = await RigDiscovery.rigctld(host: "127.0.0.1", port: port)
        XCTAssertEqual(found?.kind, .rigctld)
        let rig = try await RigctldRig.connect(host: "127.0.0.1", port: port)
        try await rig.setFrequency(14_105_000)
        try await rig.setMode(.dataUSB)
        var s = try await rig.status()
        XCTAssertEqual(s.frequency, 14_105_000)
        XCTAssertEqual(s.mode, "DATA-U")
        try await rig.setPTT(true)
        s = try await rig.status()
        XCTAssertTrue(s.transmitting)
        try await rig.setPTT(false)
        s = try await rig.status()
        XCTAssertFalse(s.transmitting)
        try await rig.tune()
        await rig.close()
    }
}
