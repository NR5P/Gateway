import CryptoKit
import Foundation

/// A radio shared by a RigHelm station, over RigHelm's LAN `CAT` session (TCP 4533).
///
/// The server greets with a nonce; the client proves the password with
/// HMAC-SHA256(password, "ftdx3000:<nonce>:CAT"). After `OK` the session carries FTDX3000 CAT
/// whatever the radio is: RigHelm translates for its 32 Yaesu, Icom, Kenwood and Elecraft
/// models. The server closes a CAT session that is silent for 5 s and un-keys a client that
/// goes away, so this polls once a second. A station without a password (or with remote
/// transmit off) drops the commands that key the radio.
public final class RigHelmRig: Rig, @unchecked Sendable {
    public static let defaultPort: UInt16 = 4533
    static let greeting = "FTDX3000-REMOTE"

    public let name: String
    /// RigHelm's key for the radio model, e.g. "ftdx3000", "ic7300".
    public let model: String
    private let stream: ByteStream
    private let inbox: Inbox
    private let lock = NSLock()
    private var state = RigStatus()
    private var keyed = false
    private var failure: Error?
    private var tasks: [Task<Void, Never>] = []

    init(stream: ByteStream, inbox: Inbox, server: String, model: String) {
        self.stream = stream
        self.inbox = inbox
        self.model = model
        name = "RigHelm \(server)" + (model.isEmpty ? "" : ": \(model)")
    }

    public static func connect(host: String, port: UInt16 = defaultPort, password: String) async throws -> RigHelmRig {
        let s = try await TCPStream.connect(host: host, port: port, timeout: 4)
        do {
            return try await open(s, password: password)
        } catch {
            await s.close()
            throw error
        }
    }

    /// Logs in on an open connection and starts polling.
    static func open(_ stream: ByteStream, password: String) async throws -> RigHelmRig {
        let inbox = Inbox(stream)
        let greet = try await inbox.line(timeout: 5, what: "waiting for the RigHelm greeting").split(separator: " ").map(String.init)
        guard greet.count >= 3, greet[0] == greeting else {
            inbox.cancel()
            throw RigError.notRigHelm(greet.joined(separator: " "))
        }
        let server = greet.dropFirst(3).joined(separator: " ")
        try await stream.write("HELLO CAT \(proof(password: password, nonce: greet[2], mode: "CAT"))\n")
        let reply = try await inbox.line(timeout: 5, what: "waiting for RigHelm to accept the login")
        let words = reply.split(separator: " ").map(String.init)
        switch words.first {
        case "OK":
            let rig = RigHelmRig(stream: stream, inbox: inbox, server: server, model: words.count > 4 ? words[4] : "")
            rig.startTasks()
            try await rig.waitFor(timeout: 3, "the frequency") { $0.frequency != nil }
            return rig
        case "DENIED":
            inbox.cancel()
            throw RigError.denied(String(reply.dropFirst("DENIED ".count)))
        default:
            inbox.cancel()
            throw RigError.notRigHelm(reply)
        }
    }

    /// Hex HMAC-SHA256 of "ftdx3000:<nonce>:<mode>"; an open server ignores it.
    static func proof(password: String, nonce: String, mode: String) -> String {
        if password.isEmpty { return "-" }
        let key = SymmetricKey(data: Data(password.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data("ftdx3000:\(nonce):\(mode)".utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private func startTasks() {
        let reader = Task { [weak self] in
            guard let inbox = self?.inbox else { return }
            do {
                while !Task.isCancelled {
                    let f = try await inbox.take(until: UInt8(ascii: ";"), timeout: 8, what: "waiting for RigHelm")
                    self?.apply(String(decoding: f, as: UTF8.self))
                }
            } catch {
                self?.lock.withLock { self?.failure = error }
            }
        }
        let poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await self.stream.write("FA;MD0;TX;")
                try? await Task.sleep(for: .seconds(1))
            }
        }
        lock.withLock { tasks = [reader, poller] }
    }

    func apply(_ frame: String) {
        let f = frame.filter { $0 >= " " && $0 != ";" }.uppercased()
        lock.withLock {
            if f.hasPrefix("FA"), let hz = Int(f.dropFirst(2)) {
                state.frequency = hz
            } else if f.hasPrefix("MD0"), f.count == 4, let c = f.last {
                state.mode = Self.modes[c] ?? state.mode
            } else if f.hasPrefix("TX"), f.count == 3 {
                state.transmitting = f.last != "0"
            }
        }
    }

    static let modes: [Character: String] = [
        "1": "LSB", "2": "USB", "3": "CW", "4": "FM", "5": "AM", "6": "RTTY-L", "7": "CW-R",
        "8": "DATA-L", "9": "RTTY-U", "A": "DATA-FM", "B": "FM-N", "C": "DATA-U", "D": "AM-N",
        "E": "C4FM", "F": "DV", "G": "WFM", "H": "DATA-AM", "I": "PSK", "J": "DATA-FMN",
    ]

    private func current() throws -> RigStatus {
        try lock.withLock {
            if let failure { throw failure }
            return state
        }
    }

    private func waitFor(timeout: TimeInterval, _ what: String, _ ok: (RigStatus) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ok(try current()) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw RigError.notConfirmed(what)
    }

    public func status() async throws -> RigStatus { try current() }

    public func setFrequency(_ hz: Int) async throws {
        try await stream.write(String(format: "FA%08d;FA;", hz))
        // Some radios tune in 10 Hz steps.
        try await waitFor(timeout: 2, "the frequency \(DialFrequency.format(hz))") { abs(($0.frequency ?? 0) - hz) < 20 }
    }

    public func setMode(_ mode: RigMode) async throws {
        try await stream.write(mode == .dataFM ? "MD0A;MD0;" : "MD0C;MD0;")
        try await waitFor(timeout: 2, "the mode \(mode.rawValue)") { $0.mode == mode.rawValue }
    }

    public func setPTT(_ on: Bool) async throws {
        lock.withLock { keyed = on }
        try await stream.write(on ? "TX1;TX;" : "TX0;TX;")
    }

    public func tune() async throws {
        try await stream.write("AC002;")
    }

    public func close() async {
        let (wasKeyed, running): (Bool, [Task<Void, Never>]) = lock.withLock {
            defer { keyed = false; tasks = [] }
            return (keyed, tasks)
        }
        running.forEach { $0.cancel() }
        if wasKeyed {
            try? await stream.write("TX0;")
            try? await Task.sleep(for: .milliseconds(100))
        }
        inbox.cancel()
        await stream.close()
    }
}
