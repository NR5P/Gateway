import Foundation
import UIKit
import WinlinkKit

struct LogLine: Identifiable, Hashable {
    enum Kind { case info, sent, received, modemSent, modemReceived, error }
    let id = UUID()
    let time = Date()
    let kind: Kind
    let text: String
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
    @Published private(set) var progress: (title: String, sending: Bool, done: Int, total: Int)?
    @Published var showModemTraffic = true

    private var task: Task<Void, Never>?
    private var modem: VARAModem?
    private var stream: ByteStream?

    func clearLog() { log.removeAll() }

    private func append(_ kind: LogLine.Kind, _ text: String) {
        log.append(LogLine(kind: kind, text: text))
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    func start(settings: AppSettings, store: MailStore) {
        guard !running else { return }
        let mycall = settings.mycall
        guard !mycall.isEmpty else {
            append(.error, "Set your call sign in Settings first.")
            return
        }
        let kind = settings.transportKind
        let gateway = settings.gateway.trimmingCharacters(in: .whitespaces).uppercased()
        if kind == .vara && gateway.isEmpty {
            append(.error, "Enter the gateway (RMS) call sign to connect to.")
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
        let cmsHost = settings.cmsHost
        let cmsPort = UInt16(clamping: settings.cmsPort)
        if kind == .vara { settings.remember(gateway: gateway) }

        running = true
        progress = nil
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            do {
                let target: String
                let conn: ByteStream
                switch kind {
                case .vara:
                    status = "Opening modem \(cfg.host):\(cfg.commandPort)"
                    append(.info, status)
                    let m = VARAModem(config: cfg)
                    m.onEvent = { e in Task { @MainActor in self.modemEvent(e) } }
                    modem = m
                    try await m.open()
                    append(.info, "Modem: \(m.version)")
                    status = "Calling \(gateway)"
                    append(.info, "Calling \(gateway) on VARA \(cfg.mode.rawValue)" + (cfg.bandwidth.map { " \($0) Hz" } ?? ""))
                    conn = try await m.connect(to: gateway)
                    target = gateway
                case .telnet:
                    status = "Connecting to \(cmsHost):\(cmsPort)"
                    append(.info, status)
                    conn = try await CMSTelnet.connect(mycall: mycall, host: cmsHost, port: cmsPort) { l in
                        Task { @MainActor in self.append(.received, l) }
                    }
                    target = CMSTelnet.targetCall
                }
                stream = conn
                status = "Connected to \(target)"
                append(.info, status)

                let session = B2FSession(mycall: mycall, targetcall: target, locator: locator, mailbox: mailbox)
                session.userAgent = .init(name: "XaraMail", version: Bundle.main.shortVersion)
                session.password = { addr in addr.addr == mycall && !password.isEmpty ? password : nil }
                session.onEvent = { e in Task { @MainActor in self.sessionEvent(e) } }
                let stats = try await session.exchange(conn)
                status = "Done: \(stats.sent.count) sent, \(stats.received.count) received"
                append(.info, status)
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
            await modem?.close()
            modem = nil
            stream = nil
            progress = nil
            running = false
            UIApplication.shared.isIdleTimerDisabled = false
            store.reload()
        }
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
            }
        case let .state(s):
            linkState = s
            if s == .closed {
                ptt = false
                busy = false
            }
        case let .ptt(on): ptt = on
        case let .busy(on): busy = on
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

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
}
