import Foundation

/// A Winlink position report: a message to QTH that puts the station on the Winlink map
/// (ported from wl2k-go's catalog package).
public struct PositionReport: Sendable {
    public var date: Date
    public var latitude: Double
    public var longitude: Double
    /// Up to 80 characters.
    public var comment: String

    public init(date: Date = Date(), latitude: Double, longitude: Double, comment: String = "") {
        (self.date, self.latitude, self.longitude, self.comment) = (date, latitude, longitude, comment)
    }

    public func message(from mycall: String) -> Message {
        var body = "DATE: \(Message.formatDate(date))\r\n"
        body += "LATITUDE: \(Self.minutes(latitude, latitude: true))\r\n"
        body += "LONGITUDE: \(Self.minutes(longitude, latitude: false))\r\n"
        let c = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.isEmpty { body += "COMMENT: \(c.prefix(80))\r\n" }
        var m = Message(from: mycall, type: "Position Report", date: date)
        m.setBody(body)
        m.subject = "POSITION REPORT"
        m.addTo("QTH")
        return m
    }

    /// Degrees and decimal minutes: 60.132 -> "60-07.9200N", -60.5 -> "060-30.0000W".
    static func minutes(_ dec: Double, latitude: Bool) -> String {
        let sign: String = dec > 0 ? (latitude ? "N" : "E") : dec < 0 ? (latitude ? "S" : "W") : " "
        let deg = Int(dec)
        let min = abs((dec - Double(deg)) * 60)
        return String(format: latitude ? "%02d-%07.4f%@" : "%03d-%07.4f%@", abs(deg), min, sign)
    }
}
