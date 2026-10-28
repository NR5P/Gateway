import Foundation

/// The radio as last read back from it.
public struct RigStatus: Equatable, Sendable {
    /// VFO frequency in Hz, nil until it has been read.
    public var frequency: Int?
    /// The radio's mode, as the front panel shows it ("DATA-U", "USB", "FM", ...).
    public var mode: String?
    public var transmitting = false

    public init(frequency: Int? = nil, mode: String? = nil, transmitting: Bool = false) {
        (self.frequency, self.mode, self.transmitting) = (frequency, mode, transmitting)
    }
}

/// The modes Gateway sets: the radio's data mode, so audio comes from the USB/rear input
/// and the mic and speech processor stay out of the way.
public enum RigMode: String, Sendable {
    case dataUSB = "DATA-U"
    case dataFM = "DATA-FM"
}

/// A radio under CAT control, through RigHelm or hamlib's rigctld.
public protocol Rig: AnyObject, Sendable {
    /// What is being controlled, for the log ("RigHelm Shack: ftdx3000").
    var name: String { get }
    func status() async throws -> RigStatus
    func setFrequency(_ hz: Int) async throws
    func setMode(_ mode: RigMode) async throws
    /// Keys or un-keys the transmitter. Sent at once: the modem's audio is about to follow.
    func setPTT(_ on: Bool) async throws
    /// Starts the antenna tuner (the radio transmits a carrier while it tunes).
    func tune() async throws
    /// Un-keys if keyed, then hangs up.
    func close() async
}

public enum RigError: Error, Equatable, LocalizedError {
    case denied(String)
    case notRigHelm(String)
    case rejected(command: String, code: Int)
    case noAnswer(String)
    case notConfirmed(String)

    public var errorDescription: String? {
        switch self {
        case let .denied(why): return "RigHelm refused the connection: \(why)"
        case let .notRigHelm(got): return "not a RigHelm station (got \(got))"
        case let .rejected(cmd, code) where code == -9:
            return "the radio refused \(cmd): transmit is blocked there"
        case let .rejected(cmd, code): return "rigctld answered \(code) to \(cmd)"
        case let .noAnswer(what): return "no answer from the radio to \(what)"
        case let .notConfirmed(what): return "the radio did not confirm \(what)"
        }
    }
}

/// Frequencies as people write them: "14105.0" kHz, "14.105" MHz or "14105000" Hz.
public enum DialFrequency {
    public static func parse(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard let v = Double(t), v > 0 else { return nil }
        let hz: Double
        if v < 1_000 { hz = v * 1_000_000 } else if v < 1_000_000 { hz = v * 1_000 } else { hz = v }
        guard (100_000...6_000_000_000).contains(hz) else { return nil }
        return Int(hz.rounded())
    }

    /// 14105000 -> "14.105.000"
    public static func format(_ hz: Int) -> String {
        let mhz = hz / 1_000_000, khz = hz / 1_000 % 1_000, rest = hz % 1_000
        return String(format: "%d.%03d.%03d", mhz, khz, rest)
    }
}
