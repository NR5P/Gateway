import Foundation
#if os(iOS)
import UIKit
#endif
import WinlinkKit

struct LogLine: Identifiable, Hashable {
    enum Kind { case info, sent, received, modemSent, modemReceived, error }
    let id = UUID()
    let time = Date()
    let kind: Kind
    let text: String

    var prefix: String {
        switch kind {
        case .sent: return ">"
        case .received: return "<"
        case .modemSent: return "»"
        case .modemReceived: return "«"
        case .info: return "·"
        case .error: return "!"
        }
    }
}

/// Every session line, every modem command (PTT and BUFFER too) and every radio command, kept
/// in Library/Logs/Gateway/session.log (~/Library/Logs on the Mac), so a failed call can be
/// read afterwards. Kept to about 5 MB: the previous file is session.1.log.
enum SessionLogFile {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Gateway")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.log")
    }()
    private static let queue = DispatchQueue(label: "gateway.sessionlog")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ prefix: String, _ text: String, at time: Date = Date()) {
        let line = "\(stamp.string(from: time)) \(prefix) \(text)\n"
        queue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 5_000_000 {
                let old = url.deletingLastPathComponent().appendingPathComponent("session.1.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

/// Runs one connection at a time: dial (VARA or telnet), exchange messages, hang up.
@MainActor
final class SessionController: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "Idle"
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var ptt = false
    @Published private(set) var busy = false
    @Published private(set) var linkState: VARALinkState = .closed
    /// The link's current speed level, bitrate and modulation, from the modem's BITRATE lines.
    @Published private(set) var speed: LinkSpeed?
    @Published private(set) var progress: (title: String, sending: Bool, done: Int, total: Int)?
    @Published var showModemTraffic = true

    private var task: Task<Void, Never>?
    private var modem: VARAModem?
    private var stream: ByteStream?
    private var rig: RigController?
    private var rigKeysPTT = false
    private var speedMode = VARAMode.hf
    private var speedBandwidth: String?

    func clearLog() { log.removeAll() }

    func append(_ kind: LogLine.Kind, _ text: String) {
        let line = LogLine(kind: kind, text: text)
        log.append(line)
        SessionLogFile.write(line.prefix, text, at: line.time)
        #if DEBUG
        // Lets tests and `swift run`-style launches watch a session from the terminal.
        FileHandle.standardError.write(Data("[session] \(text)\n".utf8))
        #endif
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    func start(settings: AppSettings, store: MailStore, rig: RigController) {
        guard !running else { return }
        let mycall = settings.mycall
        guard !mycall.isEmpty else {
            append(.error, "Set your call sign in Settings first.")
            return
        }
        let kind = settings.transportKind
        let answering = kind == .listen || (kind == .terminal && settings.terminalAnswer)
        let target = (kind == .vara ? settings.gateway : settings.peer).trimmingCharacters(in: .whitespaces).uppercased()
        if kind.usesRadio && !answering && target.isEmpty {
            append(.error, kind == .vara ? "Enter the gateway (RMS) call sign to connect to." : "Enter the call sign of the station to call.")
            return
        }
        let password = settings.password
        let locator = settings.locator.trimmingCharacters(in: .whitespaces)
        let mailbox = store.sessionMailbox { Task { @MainActor in store.reload() } }
        var cfg = VARAConfig(host: settings.modemHost.trimmingCharacters(in: .whitespaces),
                             commandPort: UInt16(clamping: settings.modemPort),
                             mycall: mycall, mode: settings.mode,
                             bandwidth: settings.mode == .hf ? settings.bandwidth : nil)
        cfg.connectTimeout = 300
        (speedMode, speedBandwidth, speed) = (cfg.mode, cfg.bandwidth, nil)
        let cmsHost = settings.cmsHost
        let cmsPort = UInt16(clamping: settings.cmsPort)
        let useRig = kind.usesRadio && settings.rigMode != .off
        let dialText = settings.dialFrequency.trimmingCharacters(in: .whitespaces)
        let dial = DialFrequency.parse(dialText)
        if useRig && !dialText.isEmpty && dial == nil {
            append(.error, "\(dialText) is not a frequency. Use kHz (14105.0) or MHz (14.105).")
            return
        }
        if kind == .vara {
            settings.remember(gateway: target)
            if let dial { settings.remember(frequency: dial, for: target) }
        }
        self.rig = useRig ? rig : nil
        rigKeysPTT = useRig && settings.rigKeysPTT
        terminal = ""
        append(.info, "Session: \(kind.rawValue) \(answering ? "listening" : target) as \(mycall)"
            + (kind.usesRadio ? ", modem \(cfg.host):\(cfg.commandPort) \(cfg.mode.rawValue)\(cfg.bandwidth.map { " \($0)" } ?? ""), dial \(dial.map { DialFrequency.format($0) + " MHz" } ?? "not set")"
                + ", radio \(useRig ? settings.rigMode.rawValue : "off")\(useRig ? (settings.rigKeysPTT ? ", Gateway keys PTT" : ", modem keys PTT") : "")" : ""))

        #if os(macOS)
        let modemCommand = settings.modemCommand
        #endif
        running = true
        progress = nil
        keepAwake(true)
        task = Task {
            do {
                if kind == .telnet {
                    status = "Connecting to \(cmsHost):\(cmsPort)"
                    append(.info, status)
                    let conn = try await CMSTelnet.connect(mycall: mycall, host: cmsHost, port: cmsPort) { l in
                        Task { @MainActor in self.append(.received, l) }
                    }
                    stream = conn
                    try await exchange(conn, mycall: mycall, target: CMSTelnet.targetCall, locator: locator, mailbox: mailbox, master: false, password: password)
                } else {
                    if useRig {
                        status = dial.map { "Tuning the radio to \(DialFrequency.format($0))" } ?? "Opening the radio"
                        do {
                            try await rig.prepare(settings: settings, frequency: dial, mode: cfg.mode == .fm ? .dataFM : .dataUSB)
                        } catch where dial != nil {
                            // Never transmit on whatever frequency the radio happens to be on.
                            throw SessionError.radio(error.localizedDescription)
                        } catch {
                            append(.error, "Radio: \(error.localizedDescription). Continuing without radio control.")
                        }
                    }
                    status = "Opening modem \(cfg.host):\(cfg.commandPort)"
                    append(.info, status)
                    let m = VARAModem(config: cfg)
                    m.onEvent = { e in Task { @MainActor in self.modemEvent(e) } }
                    modem = m
                    #if os(macOS)
                    try await ModemLauncher.shared.open(m, commandLine: modemCommand) { self.append(.info, $0) }
                    #else
                    try await m.open()
                    #endif
                    append(.info, "Modem: \(m.version)")
                    if answering {
                        // Answer calls until aborted: a P2P partner may call more than once.
                        while !Task.isCancelled {
                            status = "Listening as \(mycall) on VARA \(cfg.mode.rawValue)"
                            append(.info, status)
                            let link = try await m.accept(timeout: 24 * 3600)
                            stream = link
                            append(.info, "Call from \(link.remote)")
                            do {
                                if kind == .terminal {
                                    try await runTerminal(link, remote: link.remote)
                                } else {
                                    try await exchange(link, mycall: mycall, target: link.remote, locator: locator, mailbox: mailbox, master: true, password: password)
                                }
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                append(.error, "Session with \(link.remote) failed: \(error.localizedDescription)")
                            }
                            await m.disconnect(timeout: 30)
                            stream = nil
                        }
                    } else {
                        status = "Calling \(target)"
                        append(.info, "Calling \(target) on VARA \(cfg.mode.rawValue)" + (cfg.bandwidth.map { " \($0) Hz" } ?? ""))
                        let conn = try await m.connect(to: target)
                        stream = conn
                        if kind == .terminal {
                            try await runTerminal(conn, remote: target)
                        } else {
                            // A P2P partner is a master like a gateway; only mail addressed to it goes.
                            try await exchange(conn, mycall: mycall, target: target, locator: locator, mailbox: mailbox, master: false, password: password)
                        }
                        await m.disconnect(timeout: 30)
                    }
                }
            } catch is CancellationError {
                status = "Aborted"
                append(.error, status)
            } catch let e as B2FError where e.isLoginFailure {
                status = "Login failed: check your Winlink password"
                append(.error, e.localizedDescription)
            } catch {
                status = "Failed: \(error.localizedDescription)"
                append(.error, status)
            }
            self.rig?.sessionEnded()
            if let s = self.rig?.status, let hz = s.frequency {
                append(.info, "Radio at the end: \(DialFrequency.format(hz)) MHz \(s.mode ?? "")")
            }
            await modem?.close()
            modem = nil
            stream = nil
            progress = nil
            running = false
            keepAwake(false)
            store.reload()
        }
    }

    /// One B2F exchange: as the client (calling a gateway or a P2P station) or as the master
    /// (answering a P2P call, announcing our call so the caller sends only mail for us).
    private func exchange(_ conn: ByteStream, mycall: String, target: String, locator: String, mailbox: Mailbox, master: Bool, password: String) async throws {
        status = "Connected to \(target)"
        append(.info, status)
        let session = B2FSession(mycall: mycall, targetcall: target, locator: locator, mailbox: mailbox)
        session.isMaster = master
        session.userAgent = .init(name: "Gateway", version: Bundle.main.shortVersion)
        session.password = { addr in addr.addr == mycall && !password.isEmpty ? password : nil }
        session.onEvent = { e in Task { @MainActor in self.sessionEvent(e) } }
        let stats = try await session.exchange(conn)
        status = "Done with \(target): \(stats.sent.count) sent, \(stats.received.count) received"
        append(.info, status)
    }

    // MARK: Terminal (keyboard to keyboard: a BBS or node, or another operator)

    @Published private(set) var terminal = ""
    @Published private(set) var terminalLinked = false

    private func runTerminal(_ conn: ByteStream, remote: String) async throws {
        status = "Terminal: connected to \(remote)"
        append(.info, status)
        terminalLinked = true
        defer { terminalLinked = false }
        terminal += "*** Connected to \(remote)\n"
        while true {
            let bytes = try await conn.read()
            if bytes.isEmpty { break }
            // BBSes end lines with CR; keep printable text, tabs and line breaks.
            let text = String(decoding: bytes, as: UTF8.self)
                .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .filter { $0 == "\n" || $0 == "\t" || !($0.asciiValue.map { $0 < 32 || $0 == 127 } ?? false) }
            terminal += text
            if terminal.count > 100_000 { terminal = String(terminal.suffix(80_000)) }
        }
        terminal += "\n*** Disconnected\n"
        status = "Terminal: \(remote) disconnected"
        append(.info, status)
    }

    /// Sends a typed line over the terminal link (CR-terminated, like a packet terminal).
    func sendTerminal(_ line: String) {
        guard terminalLinked, let s = stream else { return }
        terminal += line + "\n"
        Task {
            do { try await s.write(line + "\r") } catch { append(.error, "Send failed: \(error.localizedDescription)") }
        }
    }

    /// Ends a terminal link politely (the modem disconnects), leaving listening on.
    func hangUp() {
        guard let m = modem else { return }
        Task { await m.disconnect(timeout: 30) }
    }

    #if os(macOS)
    private var activity: NSObjectProtocol?
    #endif

    /// Keeps the screen (iOS) or the Mac (no idle sleep or App Nap) awake during a session.
    private func keepAwake(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #else
        if on {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Winlink session")
        } else if let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
        #endif
    }

    /// Stops at once: ABORT to the modem (drops the RF link) or closes the socket.
    func abort() {
        guard running else { return }
        append(.error, "Aborting")
        let m = modem, s = stream
        Task {
            if let m { await m.abort() }
            if let s { await s.close() }
            if let m { await m.close() }
        }
        task?.cancel()
    }

    private func modemEvent(_ e: VARAEvent) {
        switch e {
        case let .line(l, outbound):
            if showModemTraffic && !l.hasPrefix("PTT ") && !l.hasPrefix("BUFFER") && l != "IAMALIVE" {
                append(outbound ? .modemSent : .modemReceived, l)
            } else {
                // The file keeps what the screen leaves out.
                SessionLogFile.write(outbound ? "»" : "«", l)
            }
        case let .state(s):
            linkState = s
            switch s {
            case .connecting, .idle, .closed: speed = nil
            default: break
            }
            if s == .closed {
                if ptt && rigKeysPTT { rig?.followModem(ptt: false) }
                ptt = false
                busy = false
            }
        case let .ptt(on):
            ptt = on
            if rigKeysPTT { rig?.followModem(ptt: on) }
        case let .busy(on): busy = on
        case let .bitrate(text):
            speed = LinkSpeed.parse(text, mode: speedMode, bandwidth: speedBandwidth) ?? speed
        default: break
        }
    }

    private func sessionEvent(_ e: SessionEvent) {
        switch e {
        case let .line(l, outbound): append(outbound ? .sent : .received, l)
        case let .info(s): append(.info, s)
        case let .progress(_, title, sending, done, total): progress = (title, sending, done, total)
        }
    }
}

enum SessionError: Error, LocalizedError {
    case radio(String)

    var errorDescription: String? {
        switch self {
        case let .radio(why): return "radio: \(why)"
        }
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
}
