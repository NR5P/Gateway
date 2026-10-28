import XCTest
@testable import WinlinkKit

final class GatewayDirectoryTests: XCTestCase {
    func testParseKeepsPublicVARA() throws {
        let json = """
        {"ServerName":"x","ErrorCode":0,"Gateways":[
         {"Callsign":"W1AW-10","Latitude":41.7,"Longitude":-72.7,"LastStatus":"Sun, 19 Apr 2026 14:51:00 UTC","Comments":"",
          "GatewayChannels":[
           {"SupportedModes":"VARA 2750","Frequency":7103500,"Gridsquare":"FN31","OperatingHours":"00-23","ServiceCode":"PUBLIC"},
           {"SupportedModes":"Packet 1200","Frequency":145010000,"ServiceCode":"PUBLIC"},
           {"SupportedModes":"VARA","Frequency":14108500,"ServiceCode":"EMCOMM"},
           {"SupportedModes":"VARA FM WIDE","Frequency":145090000,"ServiceCode":"PUBLIC"},
           {"SupportedModes":"VARA 2750","Frequency":7103500,"ServiceCode":"PUBLIC"}]},
         {"Callsign":"N0PKT-10","Latitude":40,"Longitude":-100,
          "GatewayChannels":[{"SupportedModes":"Packet 1200","Frequency":145010000}]}]}
        """
        let g = try GatewayDirectory.parse(Data(json.utf8))
        XCTAssertEqual(g.map(\.callsign), ["W1AW-10"])
        XCTAssertEqual(g[0].channels.count, 2)
        let hf = g[0].channels[0], fm = g[0].channels[1]
        XCTAssertEqual(hf.dial, 7_102_000)
        XCTAssertEqual(hf.bandwidth, "2750")
        XCTAssertEqual(hf.band, "40m")
        XCTAssertTrue(fm.isFM)
        XCTAssertEqual(fm.dial, 145_090_000)
        XCTAssertNil(fm.bandwidth)
        XCTAssertNotNil(g[0].lastStatus)
    }

    func testMaidenhead() throws {
        let em10 = try XCTUnwrap(Maidenhead.coordinate("EM10"))
        XCTAssertEqual(em10.lat, 30.5, accuracy: 0.01)
        XCTAssertEqual(em10.lon, -97, accuracy: 0.01)
        let fn31pr = try XCTUnwrap(Maidenhead.coordinate("FN31pr"))
        XCTAssertEqual(fn31pr.lat, 41.73, accuracy: 0.03)
        XCTAssertEqual(fn31pr.lon, -72.71, accuracy: 0.05)
        XCTAssertNil(Maidenhead.coordinate("ZZ99"))
        // Austin to Newington CT, about 2,500 km, heading north-east.
        XCTAssertEqual(Maidenhead.distance(em10, fn31pr), 2_530, accuracy: 60)
        XCTAssertEqual(Maidenhead.bearing(em10, fn31pr), 55, accuracy: 5)
    }

    func testBundledList() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../Gateway/gateways.json")
        let g = try GatewayDirectory.parse(Data(contentsOf: url))
        XCTAssertGreaterThan(g.count, 1000)
    }
}

final class PositionReportTests: XCTestCase {
    func testMinutes() {
        // wl2k-go's vectors.
        let lat: [Double: String] = [-4.974: "04-58.4400S", -0.5: "00-30.0000S", 0: "00-00.0000 ", 0.5: "00-30.0000N", 60.132: "60-07.9200N"]
        let lon: [Double: String] = [-180: "180-00.0000W", -60.5: "060-30.0000W", -0.5: "000-30.0000W", 0: "000-00.0000 ",
                                     3.5: "003-30.0000E", 153.5: "153-30.0000E", 180: "180-00.0000E"]
        for (d, s) in lat { XCTAssertEqual(PositionReport.minutes(d, latitude: true), s) }
        for (d, s) in lon { XCTAssertEqual(PositionReport.minutes(d, latitude: false), s) }
    }

    func testMessage() throws {
        let d = Date(timeIntervalSince1970: 1_800_000_000)
        let m = PositionReport(date: d, latitude: 40.704, longitude: -73.945, comment: "QRV 145.500").message(from: "N0TST")
        XCTAssertEqual(m.to.map(\.addr), ["QTH"])
        XCTAssertEqual(m.subject, "POSITION REPORT")
        XCTAssertEqual(m.type, "Position Report")
        XCTAssertEqual(String(decoding: m.body, as: UTF8.self),
                       "DATE: \(Message.formatDate(d))\r\nLATITUDE: 40-42.2400N\r\nLONGITUDE: 073-56.7000W\r\nCOMMENT: QRV 145.500\r\n")
        _ = try m.bytes()
    }
}
