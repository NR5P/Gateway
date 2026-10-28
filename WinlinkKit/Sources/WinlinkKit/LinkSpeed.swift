import Foundation

/// The speed of a VARA link, from the modem's `BITRATE (7)  549 bps TX` lines.
public struct LinkSpeed: Equatable, Sendable {
    /// The speed level, 1 (slowest) and up.
    public var level: Int
    public var bps: Int
    /// True while this station is sending, false while it is receiving.
    public var transmitting: Bool
    /// The waveform at this level, such as "6 carriers · QPSK"; nil for VARA FM.
    public var modulation: String?

    public init(level: Int, bps: Int, transmitting: Bool, modulation: String?) {
        (self.level, self.bps, self.transmitting, self.modulation) = (level, bps, transmitting, modulation)
    }

    /// Parses the text after `BITRATE`, e.g. "(7)  549 bps TX", for a link in `mode` at `bandwidth` Hz.
    public static func parse(_ text: String, mode: VARAMode, bandwidth: String?) -> LinkSpeed? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("("), let close = t.firstIndex(of: ")"),
              let level = Int(t[t.index(after: t.startIndex)..<close]) else { return nil }
        let rest = t[t.index(after: close)...].split(separator: " ")
        guard let bps = rest.first.flatMap({ Int($0) }) else { return nil }
        let modulation = mode == .hf ? modulation(level: level, bandwidth: bandwidth ?? "2300") : nil
        return LinkSpeed(level: level, bps: bps, transmitting: rest.last == "TX", modulation: modulation)
    }

    /// The waveform VARA HF uses at a level, as xara's level tables name it.
    public static func modulation(level: Int, bandwidth: String) -> String? {
        let table: [String]
        switch bandwidth {
        case "500": table = hf500
        case "2750": table = hf2750
        default: table = hf2300
        }
        return (1...table.count).contains(level) ? table[level - 1] : nil
    }

    static let hf500 = [
        "FSK", "FSK", "FSK", "2 carriers · BPSK", "2 carriers · QPSK", "3 carriers · QPSK",
        "OFDM 11 carriers · QPSK", "OFDM 11 carriers · QPSK", "OFDM 11 carriers · QPSK",
        "OFDM 11 carriers · 8PSK", "OFDM 11 carriers · 8PSK", "OFDM 11 carriers · 16QAM", "OFDM 11 carriers · 32QAM",
    ]
    static let hf2300 = [
        "FSK", "FSK", "FSK", "FSK", "3 carriers · QPSK", "4 carriers · QPSK", "6 carriers · QPSK",
        "8 carriers · QPSK", "10 carriers · QPSK", "OFDM 49 carriers · QPSK", "OFDM 49 carriers · QPSK",
        "OFDM 49 carriers · QPSK", "OFDM 49 carriers · 8PSK", "OFDM 49 carriers · 8PSK",
        "OFDM 49 carriers · 16QAM", "OFDM 49 carriers · 32QAM",
    ]
    static let hf2750 = [
        "FSK", "FSK", "FSK", "FSK", "3 carriers · QPSK", "4 carriers · QPSK", "6 carriers · QPSK",
        "8 carriers · QPSK", "10 carriers · QPSK", "13 carriers · QPSK", "OFDM 59 carriers · QPSK",
        "OFDM 59 carriers · QPSK", "OFDM 59 carriers · QPSK", "OFDM 59 carriers · 8PSK",
        "OFDM 59 carriers · 8PSK", "OFDM 59 carriers · 16QAM", "OFDM 59 carriers · 32QAM",
    ]
}
