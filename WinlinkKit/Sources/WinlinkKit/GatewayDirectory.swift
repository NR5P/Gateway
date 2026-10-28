import Foundation

/// A Winlink RMS gateway and its VARA channels, from the Winlink gateway status list
/// (api.winlink.org/gateway/status.json, the list Pat and Winlink Express use).
public struct RMSGateway: Identifiable, Hashable, Sendable {
    public var callsign: String
    public var latitude: Double
    public var longitude: Double
    public var lastStatus: Date?
    public var comments: String
    public var channels: [RMSChannel]

    public var id: String { callsign }
}

public struct RMSChannel: Identifiable, Hashable, Sendable {
    /// As listed: "VARA", "VARA 500", "VARA 2750", "VARA FM", "VARA FM WIDE".
    public var modes: String
    /// The listed (centre) frequency in Hz.
    public var frequency: Int
    public var grid: String
    /// UTC hours, e.g. "00-23".
    public var hours: String
    public var antenna: String
    public var serviceCode: String

    public var id: String { "\(modes)@\(frequency)" }

    public var isFM: Bool { modes.uppercased().contains("FM") }

    /// The radio's dial: the listed frequency is the centre of the signal, 1500 Hz above an
    /// HF (USB) dial; FM channels are listed at their dial frequency (as in Pat).
    public var dial: Int { isFM ? frequency : frequency - 1500 }

    /// VARA HF bandwidth: "VARA 500" -> 500, "VARA 2750" -> 2750, plain "VARA" -> 2300.
    public var bandwidth: String? {
        guard !isFM else { return nil }
        if modes.contains("500") { return "500" }
        if modes.contains("2750") { return "2750" }
        return "2300"
    }

    public var band: String {
        let mhz = Double(dial) / 1e6
        let bands: [(String, ClosedRange<Double>)] = [
            ("160m", 1.8...2.0), ("80m", 3.5...4.0), ("60m", 5.2...5.5), ("40m", 7.0...7.3), ("30m", 10.1...10.2),
            ("20m", 14.0...14.4), ("17m", 18.0...18.2), ("15m", 21.0...21.5), ("12m", 24.8...25.0), ("10m", 28.0...30.0),
            ("6m", 50.0...54.0), ("2m", 144.0...148.0), ("1.25m", 219.0...225.0), ("70cm", 420.0...450.0),
        ]
        return bands.first { $0.1.contains(mhz) }?.0 ?? String(format: "%.3f MHz", mhz)
    }
}

public enum GatewayDirectory {
    /// Parses the status list (or the bundled copy, which has the same shape), keeping VARA
    /// channels with public access.
    public static func parse(_ data: Data) throws -> [RMSGateway] {
        struct List: Decodable { var Gateways: [G] }
        struct G: Decodable {
            var Callsign: String
            var Latitude: Double
            var Longitude: Double
            var LastStatus: String?
            var Comments: String?
            var GatewayChannels: [C]
        }
        struct C: Decodable {
            var SupportedModes: String
            var Frequency: Double
            var Gridsquare: String?
            var OperatingHours: String?
            var Antenna: String?
            var ServiceCode: String?
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return try JSONDecoder().decode(List.self, from: data).Gateways.compactMap { g in
            let ch = g.GatewayChannels
                .filter { $0.SupportedModes.uppercased().hasPrefix("VARA") && ($0.ServiceCode ?? "PUBLIC").contains("PUBLIC") }
                .map { RMSChannel(modes: $0.SupportedModes, frequency: Int($0.Frequency), grid: $0.Gridsquare ?? "",
                                  hours: $0.OperatingHours ?? "", antenna: $0.Antenna ?? "", serviceCode: $0.ServiceCode ?? "") }
                .sorted { $0.frequency < $1.frequency }
                // The list repeats some channels (one entry per service code).
                .reduce(into: [RMSChannel]()) { out, c in if !out.contains(where: { $0.id == c.id }) { out.append(c) } }
            guard !ch.isEmpty, abs(g.Latitude) <= 90, abs(g.Longitude) <= 180 else { return nil }
            return RMSGateway(callsign: g.Callsign, latitude: g.Latitude, longitude: g.Longitude,
                              lastStatus: g.LastStatus.flatMap(df.date(from:)), comments: g.Comments ?? "", channels: ch)
        }
    }

    /// Downloads the current list. The Winlink API wants a key issued to the program by the
    /// Winlink Development Team (one per program; ask them at winlink.org).
    public static func fetch(key: String) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://api.winlink.org/gateway/status.json")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [.init(name: "Mode", value: "AnyAll"), .init(name: "HistoryHours", value: "48"),
                           .init(name: "ServiceCodes", value: "PUBLIC"), .init(name: "key", value: key)]
        req.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw GatewayDirectoryError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        // A bad key comes back as 200 with an error status and no gateways.
        guard try !parse(data).isEmpty else { throw GatewayDirectoryError.empty }
        return data
    }
}

public enum GatewayDirectoryError: Error, LocalizedError {
    case http(Int), empty

    public var errorDescription: String? {
        switch self {
        case let .http(code): return "the Winlink API answered HTTP \(code)"
        case .empty: return "the Winlink API returned no gateways (check the API key)"
        }
    }
}

/// Maidenhead grid locators and great-circle distances.
public enum Maidenhead {
    /// The centre of a 4- or 6-character locator ("EM10", "EM10dk").
    public static func coordinate(_ locator: String) -> (lat: Double, lon: Double)? {
        let c = Array(locator.uppercased())
        guard c.count >= 4, c.count % 2 == 0,
              let a = c[0].asciiValue, let b = c[1].asciiValue, (65...82).contains(a), (65...82).contains(b),
              let d0 = c[2].wholeNumberValue, let d1 = c[3].wholeNumberValue
        else { return nil }
        var lon = Double(a - 65) * 20 - 180 + Double(d0) * 2
        var lat = Double(b - 65) * 10 - 90 + Double(d1)
        if c.count >= 6, let e = c[4].asciiValue, let f = c[5].asciiValue, (65...88).contains(e), (65...88).contains(f) {
            lon += Double(e - 65) * (2.0 / 24) + 1.0 / 24
            lat += Double(f - 65) * (1.0 / 24) + 0.5 / 24
        } else {
            lon += 1
            lat += 0.5
        }
        return (lat, lon)
    }

    /// Great-circle distance in km.
    public static func distance(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double)) -> Double {
        let r = 6371.0, p = Double.pi / 180
        let dlat = (b.lat - a.lat) * p, dlon = (b.lon - a.lon) * p
        let h = sin(dlat / 2) * sin(dlat / 2) + cos(a.lat * p) * cos(b.lat * p) * sin(dlon / 2) * sin(dlon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// Initial bearing in degrees from north.
    public static func bearing(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double)) -> Double {
        let p = Double.pi / 180
        let y = sin((b.lon - a.lon) * p) * cos(b.lat * p)
        let x = cos(a.lat * p) * sin(b.lat * p) - sin(a.lat * p) * cos(b.lat * p) * cos((b.lon - a.lon) * p)
        return (atan2(y, x) / p + 360).truncatingRemainder(dividingBy: 360)
    }
}
