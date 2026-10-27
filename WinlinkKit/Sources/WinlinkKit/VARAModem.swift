// A client for the VARA TNC TCP interface: a command port (default 8300)
// carrying CR-terminated text lines, and a data port (command port + 1)
// carrying the ARQ payload. Works with VARA HF/FM and with xara.
//
// The command sequence follows Pat's VARA driver (github.com/n8jja/Pat-Vara, MIT).

import Foundation

public enum VARAMode: String, Codable, CaseIterable, Sendable {
    case hf = "HF"
    case fm = "FM"
}

public struct VARAConfig: Sendable {
    public var host: String
    public var commandPort: UInt16
    public var dataPort: UInt16
    public var mycall: String
    public var mode: VARAMode
    /// "500", "2300" or "2750"; HF only. Nil leaves the modem's setting alone.
    public var bandwidth: String?
    /// How long to wait for a reply to a setup command.
    public var commandTimeout: TimeInterval = 5
    /// How long a CONNECT may take before we give up and abort.
    public var connectTimeout: TimeInterval = 300

    public init(host: String = "127.0.0.1", commandPort: UInt16 = 8300, dataPort: UInt16? = nil, mycall: String,
                mode: VARAMode = .hf, bandwidth: String? = "2300") {
        self.host = host
        self.commandPort = commandPort
        self.dataPort = dataPort ?? commandPort &+ 1
        self.mycall = mycall.uppercased()
        self.mode = mode
        self.bandwidth = bandwidth
    }
}

public enum VARALinkState: Equatable, Sendable {
    case closed
    case idle
    case connecting(String)
    case connected(caller: String, answerer: String, width: String)
    case disconnecting
}

public enum VARAEvent: Sendable {
    /// A command-port line; `outbound` is true for what we sent.
    case line(String, outbound: Bool)
    case state(VARALinkState)
    case ptt(Bool)
    case busy(Bool)
    case buffer(Int)
    case bitrate(String)
    case snr(Double)
}

public enum VARAError: Error, Equatable, LocalizedError {
    case rejected(String)
    case notVARA(String)
    case connectFailed(String)
    case busyChannel
    case modemClosed
    case notIdle

    public var errorDescription: String? {
        switch self {
        case let .rejected(cmd): return "modem rejected \(cmd)"
        case let .notVARA(s): return "not a VARA modem (got \(s))"
        case let .connectFailed(s): return "connect failed: \(s)"
        case .busyChannel: return "channel busy"
        case .modemClosed: return "modem connection closed"
        case .notIdle: return "modem is not idle"
        }
    }
}

public final class VARAModem: @unchecked Sendable {
    public let config: VARAConfig
    /// Called on an internal thread for every command-port line and state change.
    public var onEvent: (VARAEvent) -> Void = { _ in }

    private let lock = NSLock()
    private var cmd: TCPStream?
    private var data: TCPStream?
    private var waiters: [UUID: Waiter] = [:]
    private var _state: VARALinkState = .closed
    private var _buffer = 0
    private var _busy = false
    private var _ptt = false
    private var _version = ""
    private var link: VARAConnection?
    private var tasks: [Task<Void, Never>] = []
    private let commandGate = AsyncGate()

    private struct Waiter {
        let match: (String) -> Bool
        let cont: CheckedContinuation<String, Error>
    }

    public init(config: VARAConfig) {
        self.config = config
    }

    public var state: VARALinkState { lock.withLock { _state } }
    public var buffer: Int { lock.withLock { _buffer } }
    public var busy: Bool { lock.withLock { _busy } }
    public var ptt: Bool { lock.withLock { _ptt } }
    public var version: String { lock.withLock { _version } }

    // MARK: Lifecycle

    /// Connects both ports and sets the modem up for a Winlink session.
    public func open() async throws {
        let c = try await TCPStream.connect(host: config.host, port: config.commandPort)
        let d: TCPStream
        do {
            d = try await TCPStream.connect(host: config.host, port: config.dataPort)
        } catch {
            await c.close()
            throw error
        }
        lock.withLock {
            cmd = c
            data = d
        }
        setState(.idle)
        let readers: [Task<Void, Never>] = [
            Task { [weak self] in await self?.commandLoop(c) },
            Task { [weak self] in await self?.dataLoop(d) },
        ]
        lock.withLock { tasks = readers }

        do {
            let v = try await command("VERSION", expect: { $0.hasPrefix("VERSION") || $0 == "WRONG" })
            guard v.hasPrefix("VERSION") else { throw VARAError.notVARA(v) }
            lock.withLock { _version = String(v.dropFirst("VERSION ".count)) }
            try await optional("PUBLIC ON")
            if config.mode == .hf { try await optional("CWID ON") }
            try await optional("COMPRESSION TEXT")
            try await required("MYCALL \(config.mycall)")
            try await optional("LISTEN OFF")
            if config.mode == .hf, let bw = config.bandwidth {
                try await required("BW\(bw)")
            }
            if config.mode == .hf { try await optional("WINLINK SESSION") }
        } catch {
            await close()
            throw error
        }
    }

    /// Disconnects any link and closes both ports.
    public func close() async {
        if case .connected = state {
            await disconnect()
        }
        let (c, d, ts): (TCPStream?, TCPStream?, [Task<Void, Never>]) = lock.withLock {
            defer {
                cmd = nil
                data = nil
                tasks = []
            }
            return (cmd, data, tasks)
        }
        await c?.close()
        await d?.close()
        for t in ts { t.cancel() }
        modemGone()
    }

    // MARK: Commands

    /// Sends a command line and returns the first reply line matching `expect` (default OK/WRONG).
    @discardableResult
    public func command(_ line: String, expect: ((String) -> Bool)? = nil, timeout: TimeInterval? = nil) async throws -> String {
        await commandGate.enter()
        let match = expect ?? { $0 == "OK" || $0 == "WRONG" }
        do {
            let r = try await waitFor(match, timeout: timeout ?? config.commandTimeout, what: line) {
                try await self.send(line)
            }
            await commandGate.leave()
            return r
        } catch {
            await commandGate.leave()
            throw error
        }
    }

    private func required(_ line: String) async throws {
        let r = try await command(line)
        if r == "WRONG" { throw VARAError.rejected(line) }
    }

    /// Commands some modems do not know; a WRONG or no answer is only logged.
    private func optional(_ line: String) async throws {
        do {
            try await command(line)
        } catch StreamError.timeout {
            onEvent(.line("(no reply to \(line))", outbound: false))
        }
    }

    private func send(_ line: String) async throws {
        guard let c = lock.withLock({ cmd }) else { throw VARAError.modemClosed }
        onEvent(.line(line, outbound: true))
        try await c.write(line + "\r")
    }

    /// Registers a waiter, runs `then` (usually sending a command), and waits for a matching line.
    private func waitFor(_ match: @escaping (String) -> Bool, timeout: TimeInterval, what: String,
                         then: @escaping () async throws -> Void) async throws -> String {
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled { self?.fail(id, StreamError.timeout("waiting for a reply to \(what)")) }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
                let open = lock.withLock { () -> Bool in
                    guard cmd != nil else { return false }
                    waiters[id] = Waiter(match: match, cont: c)
                    return true
                }
                guard open else {
                    c.resume(throwing: VARAError.modemClosed)
                    return
                }
                Task {
                    do { try await then() } catch { self.fail(id, error) }
                }
            }
        } onCancel: {
            self.fail(id, CancellationError())
        }
    }

    private func fail(_ id: UUID, _ error: Error) {
        let w = lock.withLock { waiters.removeValue(forKey: id) }
        w?.cont.resume(throwing: error)
    }

    // MARK: Linking

    /// Calls `target` and returns the ARQ link once the modem reports CONNECTED.
    public func connect(to target: String, via: [String] = []) async throws -> VARAConnection {
        guard state == .idle else { throw VARAError.notIdle }
        let target = target.uppercased()
        // Attach the link before calling: the gateway's first bytes can beat CONNECTED to us.
        let conn = VARAConnection(modem: self, remote: target)
        lock.withLock {
            _buffer = 0
            link = conn
        }
        setState(.connecting(target))
        let line = via.isEmpty ? "CONNECT \(config.mycall) \(target)" : "CONNECT \(config.mycall) \(target) VIA \(via.joined(separator: " "))"
        let reply: String
        do {
            reply = try await waitFor({ $0.hasPrefix("CONNECTED ") || $0 == "DISCONNECTED" || $0 == "WRONG" },
                                      timeout: config.connectTimeout, what: line) {
                try await self.send(line)
            }
        } catch {
            linkGone()
            if state != .closed {
                try? await send("ABORT")
                setState(.idle)
            }
            throw error
        }
        switch reply {
        case "WRONG":
            linkGone()
            setState(.idle)
            throw VARAError.rejected(line)
        case "DISCONNECTED":
            setState(.idle)
            throw VARAError.connectFailed("no answer from \(target)")
        default:
            return conn
        }
    }

    /// Listens for an incoming call (P2P, or a test gateway) and returns the link once connected.
    public func accept(timeout: TimeInterval = 3600) async throws -> VARAConnection {
        guard state == .idle else { throw VARAError.notIdle }
        let conn = VARAConnection(modem: self, remote: "")
        lock.withLock {
            _buffer = 0
            link = conn
        }
        do {
            try await required("LISTEN ON")
            let reply = try await waitFor({ $0.hasPrefix("CONNECTED ") }, timeout: timeout, what: "an incoming call") {}
            let p = reply.split(separator: " ")
            conn.remote = p.count > 1 ? String(p[1]) : ""
            return conn
        } catch {
            linkGone()
            _ = try? await command("LISTEN OFF")
            throw error
        }
    }

    /// Asks the modem to end the link gracefully, falling back to ABORT after `timeout`.
    public func disconnect(timeout: TimeInterval = 60) async {
        switch state {
        case .connected, .connecting, .disconnecting:
            break
        default:
            return
        }
        setState(.disconnecting)
        do {
            _ = try await waitFor({ $0 == "DISCONNECTED" }, timeout: timeout, what: "DISCONNECT") {
                try await self.send("DISCONNECT")
            }
        } catch {
            await abort()
        }
    }

    /// Drops the link at once.
    public func abort() async {
        try? await send("ABORT")
        linkGone()
        if state != .closed { setState(.idle) }
    }

    /// Waits for the modem's TX buffer to drop below `limit` bytes (or to empty when limit is 1).
    func waitForBuffer(below limit: Int, timeout: TimeInterval = 120) async throws {
        while true {
            let (n, s) = lock.withLock { (_buffer, _state) }
            guard case .connected = s else { throw StreamError.closed }
            if n < limit { return }
            // Each BUFFER report resets the timeout: the link is alive as long as it drains.
            _ = try await waitFor({ $0.hasPrefix("BUFFER") || $0 == "DISCONNECTED" }, timeout: timeout, what: "buffer to drain") {}
        }
    }

    func noteWritten(_ n: Int) { lock.withLock { _buffer += n } }

    func writeData(_ bytes: [UInt8]) async throws {
        guard let d = lock.withLock({ data }) else { throw VARAError.modemClosed }
        try await d.write(bytes)
    }

    // MARK: Readers

    private func commandLoop(_ c: TCPStream) async {
        var pending: [UInt8] = []
        while true {
            guard let chunk = try? await c.read(), !chunk.isEmpty else { break }
            pending += chunk
            while let i = pending.firstIndex(of: 13) {
                let line = String(decoding: pending[..<i], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                pending.removeFirst(i + 1)
                if !line.isEmpty { handle(line) }
            }
        }
        modemGone()
    }

    private func dataLoop(_ d: TCPStream) async {
        while true {
            guard let chunk = try? await d.read(), !chunk.isEmpty else { break }
            // Data outside a link is stale; drop it.
            lock.withLock { link }?.deliver(chunk)
        }
    }

    private func handle(_ line: String) {
        onEvent(.line(line, outbound: false))
        switch line {
        case "PTT ON", "PTT OFF":
            let on = line == "PTT ON"
            lock.withLock { _ptt = on }
            onEvent(.ptt(on))
        case "BUSY ON", "BUSY OFF":
            let on = line == "BUSY ON"
            lock.withLock { _busy = on }
            onEvent(.busy(on))
        case "DISCONNECTED":
            linkGone()
            if state != .closed { setState(.idle) }
        default:
            if line.hasPrefix("BUFFER ") {
                let n = Int(line.dropFirst(7).trimmingCharacters(in: .whitespaces)) ?? 0
                lock.withLock { _buffer = n }
                onEvent(.buffer(n))
            } else if line.hasPrefix("CONNECTED ") {
                // CONNECTED <caller> <answerer> [VIA ...] <width>
                let p = line.split(separator: " ").map(String.init)
                setState(.connected(caller: p.count > 1 ? p[1] : "", answerer: p.count > 2 ? p[2] : "", width: p.last ?? ""))
            } else if line.hasPrefix("BITRATE") {
                onEvent(.bitrate(String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("SN "), let v = Double(line.dropFirst(3)) {
                onEvent(.snr(v))
            }
        }
        let matched: [Waiter] = lock.withLock {
            let ids = waiters.filter { $0.value.match(line) }.map(\.key)
            return ids.compactMap { waiters.removeValue(forKey: $0) }
        }
        for w in matched { w.cont.resume(returning: line) }
    }

    private func setState(_ s: VARALinkState) {
        let changed = lock.withLock { () -> Bool in
            defer { _state = s }
            return _state != s
        }
        if changed { onEvent(.state(s)) }
    }

    private func linkGone() {
        let l = lock.withLock { () -> VARAConnection? in
            defer { link = nil }
            return link
        }
        l?.remoteClosed()
    }

    private func modemGone() {
        linkGone()
        let ws: [Waiter] = lock.withLock {
            defer { waiters = [:] }
            cmd = nil
            return Array(waiters.values)
        }
        for w in ws { w.cont.resume(throwing: VARAError.modemClosed) }
        setState(.closed)
    }
}

/// The ARQ link to the remote station, carried on the modem's data port.
public final class VARAConnection: ByteStream, @unchecked Sendable {
    public internal(set) var remote: String
    private weak var modem: VARAModem?
    private let lock = NSLock()
    private var inbox: [[UInt8]] = []
    private var waiter: CheckedContinuation<[UInt8], Never>?
    private var ended = false
    private var lastWrite = Date.distantPast

    init(modem: VARAModem, remote: String) {
        self.modem = modem
        self.remote = remote
    }

    func deliver(_ b: [UInt8]) {
        let w: CheckedContinuation<[UInt8], Never>? = lock.withLock {
            if let w = waiter {
                waiter = nil
                return w
            }
            inbox.append(b)
            return nil
        }
        w?.resume(returning: b)
    }

    func remoteClosed() {
        // Data the modem sent just before DISCONNECTED may still be in flight on the data port.
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let w: CheckedContinuation<[UInt8], Never>? = self.lock.withLock {
                self.ended = true
                defer { self.waiter = nil }
                return self.waiter
            }
            w?.resume(returning: [])
        }
    }

    public func read() async throws -> [UInt8] {
        await withCheckedContinuation { c in
            lock.lock()
            if !inbox.isEmpty {
                let b = inbox.removeFirst()
                lock.unlock()
                c.resume(returning: b)
            } else if ended {
                lock.unlock()
                c.resume(returning: [])
            } else {
                waiter = c
                lock.unlock()
            }
        }
    }

    public func write(_ bytes: [UInt8]) async throws {
        guard let m = modem, !lock.withLock({ ended }) else { throw StreamError.closed }
        // Keep the modem's queue short so a flush means "on the air", as Pat does.
        try await m.waitForBuffer(below: max(7 * bytes.count, 1))
        m.noteWritten(bytes.count)
        lock.withLock { lastWrite = Date() }
        try await m.writeData(bytes)
    }

    public func flush() async throws {
        guard let m = modem else { throw StreamError.closed }
        if lock.withLock({ ended }) { return }
        try await m.waitForBuffer(below: 1)
    }

    public func close() async {
        guard let m = modem else { return }
        if !lock.withLock({ ended }) {
            // Let the last frame go out before asking to disconnect.
            let since = Date().timeIntervalSince(lock.withLock { lastWrite })
            if since < 2 { try? await Task.sleep(nanoseconds: UInt64((2 - since) * 1_000_000_000)) }
            try? await m.waitForBuffer(below: 1, timeout: 60)
            await m.disconnect()
        }
    }
}

/// A FIFO async mutex so command/reply pairs do not interleave.
actor AsyncGate {
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { queue.append($0) }
    }

    func leave() {
        if queue.isEmpty {
            busy = false
        } else {
            queue.removeFirst().resume()
        }
    }
}
