import Foundation
import WinlinkKit

/// The radio: finds it (RigHelm on the LAN or this Mac, or a rigctld), keeps a CAT session
/// open while it is in use, sets frequency and mode before a call, and keys the transmitter
/// when the modem says PTT ON.
///
/// Transmit safety: keying only follows the modem's PTT (or the Tune button), always in the
/// order the modem sent it; a PTT held longer than `maxKeyed` is dropped; the radio is
/// un-keyed when a session ends, the rig is disconnected or the app quits.
@MainActor
final class RigController: ObservableObject {
    @Published private(set) var endpoints: [RigEndpoint] = []
    @Published private(set) var scanning = false
    @Published private(set) var connected: String?
    @Published private(set) var status = RigStatus()
    @Published private(set) var message = ""

    /// Longest the modem may hold PTT before this lets go (VARA frames are a few seconds).
    static let maxKeyed: Duration = .seconds(45)

    var log: (LogLine.Kind, String) -> Void = { _, _ in }

    private var rig: Rig?
    private var connecting: Task<Rig, Error>?
    private var poller: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var pttQueue: AsyncStream<Bool>.Continuation?
    private var pttWorker: Task<Void, Never>?

    func scan(settings: AppSettings) async {
        guard !scanning else { return }
        scanning = true
        let modemHost = settings.modemHost.trimmingCharacters(in: .whitespaces)
        endpoints = await RigDiscovery.scan(hosts: modemHost == "127.0.0.1" ? [] : [modemHost])
        scanning = false
        message = endpoints.isEmpty ? "No radio found. Start RigHelm (or rigctld) on the computer the radio is plugged into." : ""
    }

    /// The open rig, connecting (and on Automatic, searching) first if need be.
    @discardableResult
    func open(settings: AppSettings) async throws -> Rig {
        if let rig { return rig }
        if let connecting { return try await connecting.value }
        let t = Task { try await self.connect(settings: settings) }
        connecting = t
        defer { connecting = nil }
        let r = try await t.value
        rig = r
        connected = r.name
        message = ""
        log(.info, "Radio: connected to \(r.name)")
        startPolling(r)
        return r
    }

    private func connect(settings: AppSettings) async throws -> Rig {
        let password = settings.rigPassword
        switch settings.rigMode {
        case .off:
            throw RigControlError.off
        case .righelm:
            return try await RigHelmRig.connect(host: settings.rigHost, port: UInt16(clamping: settings.rigPort), password: password)
        case .rigctld:
            return try await RigctldRig.connect(host: settings.rigHost, port: UInt16(clamping: settings.rigPort))
        case .auto:
            if endpoints.isEmpty { await scan(settings: settings) }
            // The last radio used first, then RigHelm before rigctld, this machine before the LAN.
            let ranked = endpoints.sorted { rank($0, settings) < rank($1, settings) }
            var last: Error = RigControlError.notFound
            for e in ranked {
                do {
                    let r: Rig = e.kind == .righelm
                        ? try await RigHelmRig.connect(host: e.host, port: e.port, password: password)
                        : try await RigctldRig.connect(host: e.host, port: e.port)
                    settings.rigLastEndpoint = e.id
                    return r
                } catch {
                    log(.error, "Radio: \(e.title): \(error.localizedDescription)")
                    last = error
                }
            }
            throw last
        }
    }

    private func rank(_ e: RigEndpoint, _ settings: AppSettings) -> Int {
        (e.id == settings.rigLastEndpoint ? 0 : 10)
            + (e.kind == .righelm ? 0 : 4)
            + (e.host == "127.0.0.1" ? 0 : 2)
            + (e.kind == .righelm && e.radio != "connected" ? 1 : 0)
    }

    private func startPolling(_ r: Rig) {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let s = try await r.status()
                    self?.status = s
                } catch {
                    self?.lost(error)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func lost(_ error: Error) {
        guard let r = rig else { return }
        log(.error, "Radio: lost \(r.name): \(error.localizedDescription)")
        message = "Lost the radio: \(error.localizedDescription)"
        disconnect()
    }

    func disconnect() {
        poller?.cancel()
        watchdog?.cancel()
        pttQueue?.finish()
        pttQueue = nil
        pttWorker = nil
        if let r = rig { Task { await r.close() } }
        rig = nil
        connected = nil
        status = RigStatus()
    }

    /// Before a call: the gateway's dial frequency and the data mode.
    func prepare(settings: AppSettings, frequency: Int?, mode: RigMode) async throws {
        let r = try await open(settings: settings)
        if let hz = frequency {
            try await r.setFrequency(hz)
            log(.info, "Radio: \(DialFrequency.format(hz)) MHz")
        }
        if settings.rigSetDataMode {
            try await r.setMode(mode)
            log(.info, "Radio: \(mode.rawValue)")
        }
        status = try await r.status()
    }

    /// Starts the antenna tuner. The radio transmits a carrier until it finishes.
    func tune(settings: AppSettings) async {
        do {
            let r = try await open(settings: settings)
            try await r.tune()
            log(.info, "Radio: tuning")
            message = "Tuning…"
            try? await Task.sleep(for: .seconds(4))
            if message == "Tuning…" { message = "" }
        } catch {
            message = "Tune failed: \(error.localizedDescription)"
            log(.error, "Radio: \(message)")
        }
    }

    /// Follows the modem's PTT, in order. Nothing is keyed unless the rig is already open.
    func followModem(ptt on: Bool) {
        guard let r = rig else { return }
        if pttQueue == nil {
            let (stream, cont) = AsyncStream<Bool>.makeStream()
            pttQueue = cont
            pttWorker = Task { [weak self] in
                for await key in stream {
                    do {
                        try await r.setPTT(key)
                    } catch {
                        self?.log(.error, "Radio: PTT \(key ? "on" : "off") failed: \(error.localizedDescription)")
                    }
                }
            }
        }
        pttQueue?.yield(on)
        watchdog?.cancel()
        if on {
            watchdog = Task { [weak self] in
                try? await Task.sleep(for: Self.maxKeyed)
                guard !Task.isCancelled, let self else { return }
                self.log(.error, "Radio: PTT on for over \(Self.maxKeyed.components.seconds) s, un-keying")
                self.pttQueue?.yield(false)
            }
            // A station that blocks transmit drops the command silently; say so.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard let self, let s = try? await r.status(), self.watchdog?.isCancelled == false else { return }
                if !s.transmitting {
                    self.log(.error, "Radio: did not key. On RigHelm, set a password and allow remote transmit.")
                }
            }
        }
    }

    /// After a session: make sure the transmitter is off.
    func sessionEnded() {
        watchdog?.cancel()
        pttQueue?.yield(false)
    }
}

enum RigControlError: Error, LocalizedError {
    case off, notFound

    var errorDescription: String? {
        switch self {
        case .off: return "radio control is off"
        case .notFound: return "no radio found (RigHelm or rigctld)"
        }
    }
}
