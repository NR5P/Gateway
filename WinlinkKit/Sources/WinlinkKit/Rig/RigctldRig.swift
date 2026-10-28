import Foundation

/// Hamlib's NET rigctl protocol (rigctld, RigHelm's built-in server, flrig's emulation...).
/// One request at a time: a Set answers `RPRT n`, a Get answers its values or `RPRT -n`.
public actor RigctldRig: Rig {
    public static let defaultPort: UInt16 = 4532

    public nonisolated let name: String
    private let stream: ByteStream
    private let inbox: Inbox
    private var tail: Task<Void, Never>?
    private var keyed = false

    init(stream: ByteStream, name: String) {
        self.stream = stream
        self.name = name
        inbox = Inbox(stream)
    }

    public static func connect(host: String, port: UInt16 = defaultPort) async throws -> RigctldRig {
        let s = try await TCPStream.connect(host: host, port: port, timeout: 4)
        let rig = RigctldRig(stream: s, name: "rigctld \(host):\(port)")
        do {
            _ = try await rig.status()
        } catch {
            await rig.close()
            throw error
        }
        return rig
    }

    /// Runs `body` after every earlier request has finished, so answers stay paired.
    private func exclusive<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let prev = tail
        let t = Task { () async throws -> T in
            _ = await prev?.value
            return try await body()
        }
        tail = Task { _ = try? await t.value }
        return try await t.value
    }

    private func lines(_ cmd: String, count: Int) async throws -> [String] {
        try await stream.write(cmd + "\n")
        var out: [String] = []
        while out.count < count {
            let l = try await inbox.line(timeout: 3, what: "waiting for rigctld to answer \(cmd)")
            if l.hasPrefix("RPRT ") {
                throw RigError.rejected(command: cmd, code: Int(l.dropFirst(5)) ?? -1)
            }
            out.append(l)
        }
        return out
    }

    private func set(_ cmd: String) async throws {
        try await stream.write(cmd + "\n")
        let l = try await inbox.line(timeout: 3, what: "waiting for rigctld to answer \(cmd)")
        let code = l.hasPrefix("RPRT ") ? Int(l.dropFirst(5)) ?? -1 : -1
        if code != 0 { throw RigError.rejected(command: cmd, code: code) }
    }

    public func status() async throws -> RigStatus {
        try await exclusive { [self] in
            let f = try await lines("f", count: 1)
            let m = try await lines("m", count: 2)
            let t = try await lines("t", count: 1)
            return RigStatus(frequency: Double(f[0]).map { Int($0) }, mode: Self.label(hamlib: m[0]), transmitting: t[0] != "0")
        }
    }

    public func setFrequency(_ hz: Int) async throws {
        try await exclusive { [self] in try await set("F \(hz)") }
    }

    public func setMode(_ mode: RigMode) async throws {
        // Passband 0: the radio's default width for the mode.
        try await exclusive { [self] in try await set("M \(mode == .dataFM ? "PKTFM" : "PKTUSB") 0") }
    }

    public func setPTT(_ on: Bool) async throws {
        keyed = on
        try await exclusive { [self] in try await set("T \(on ? 1 : 0)") }
    }

    public func tune() async throws {
        try await exclusive { [self] in try await set("G TUNE") }
    }

    public func close() async {
        if keyed {
            keyed = false
            try? await stream.write("T 0\n")
            try? await Task.sleep(for: .milliseconds(100))
        }
        inbox.cancel()
        await stream.close()
    }

    static func label(hamlib m: String) -> String {
        switch m {
        case "PKTUSB": return "DATA-U"
        case "PKTLSB": return "DATA-L"
        case "PKTFM": return "DATA-FM"
        case "PKTAM": return "DATA-AM"
        case "RTTYR": return "RTTY-U"
        case "RTTY": return "RTTY-L"
        default: return m
        }
    }
}
