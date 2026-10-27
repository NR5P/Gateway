#if os(macOS)
import AppKit
import Foundation
import WinlinkKit

/// Starts the local xara modem on demand: Xara.app through its `xara://start` URL when it is
/// installed, otherwise the `xara` command with the user's command line.
@MainActor
final class ModemLauncher {
    static let shared = ModemLauncher()
    nonisolated static let xaraBundleID = "io.github.x0rro.xara.mac"
    nonisolated static let defaultCommandLine = "xara --call {call} --hf 2300 --port {port} --capture default --playback YOUR_RADIO_INTERFACE"
    nonisolated static let searchPaths = ["~/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin"]

    private var process: Process?
    /// True once Xara.app, opened by us, answered; then "stop on quit" sends xara://stop.
    private var startedApp = false

    var logURL: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Gateway")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("xara.log")
    }

    nonisolated static func isLocal(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
    }

    /// Opens the modem, starting xara first if nothing answers on the command port.
    func open(_ modem: VARAModem, commandLine: String, log: @escaping (String) -> Void) async throws {
        do {
            try await modem.open()
            return
        } catch {
            guard Self.isLocal(modem.config.host), case TCPError.connect = error else { throw error }
        }
        log("No modem on \(modem.config.host):\(modem.config.commandPort); starting xara")
        let call = modem.config.mycall, port = modem.config.commandPort
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.xaraBundleID),
           let url = URL(string: "xara://start") {
            log("Opening \(app.lastPathComponent) (xara://start)")
            NSWorkspace.shared.open(url)
            if try await poll(modem) {
                // Only a modem that actually served us is ours to stop later.
                startedApp = true
                return
            }
            // Xara.app may be set to another port; the command line names this one.
            guard Self.resolve(Self.split(commandLine).first ?? "") != nil else { throw LaunchError.noAnswer }
            log("Xara.app did not answer on port \(port); trying the xara command")
        }
        try startCommand(call: call, port: port, commandLine: commandLine, log: log)
        if try await poll(modem) { return }
        throw LaunchError.noAnswer
    }

    /// Tries to open the modem every half second for up to 10 seconds.
    private func poll(_ modem: VARAModem) async throws -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
            if let p = process, !p.isRunning {
                throw LaunchError.exited(status: p.terminationStatus, tail: logTail())
            }
            do {
                try await modem.open()
                return true
            } catch TCPError.connect {
                continue
            }
        }
        return false
    }

    private func startCommand(call: String, port: UInt16, commandLine: String, log: (String) -> Void) throws {
        if let p = process, p.isRunning { return }
        var args = Self.split(commandLine.replacingOccurrences(of: "{call}", with: call)
            .replacingOccurrences(of: "{port}", with: String(port)))
        guard !args.isEmpty else { throw LaunchError.notInstalled }
        let exe = args.removeFirst()
        guard let path = Self.resolve(exe) else { throw LaunchError.notInstalled }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: logURL)
        p.standardOutput = out
        p.standardError = out
        try p.run()
        process = p
        log("Started \(path) \(args.joined(separator: " ")) (log: \(logURL.path))")
    }

    /// Stops a modem this app started (used when "Stop xara when Gateway quits" is on).
    func stopIfStarted() {
        if let p = process, p.isRunning {
            p.interrupt()
        }
        if startedApp, let url = URL(string: "xara://stop") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated static func resolve(_ exe: String) -> String? {
        if exe.contains("/") {
            let p = (exe as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: p) ? p : nil
        }
        for dir in searchPaths {
            let p = ((dir as NSString).expandingTildeInPath as NSString).appendingPathComponent(exe)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Splits a command line on spaces, honouring single and double quotes.
    nonisolated static func split(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character?
        var have = false
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                have = true
            } else if ch == " " || ch == "\t" {
                if have || !cur.isEmpty { out.append(cur) }
                cur = ""
                have = false
            } else {
                cur.append(ch)
            }
        }
        if have || !cur.isEmpty { out.append(cur) }
        return out
    }

    private func logTail() -> String {
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").suffix(3).joined(separator: "\n")
    }

    enum LaunchError: Error, LocalizedError {
        case notInstalled
        case noAnswer
        case exited(status: Int32, tail: String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "No modem is running and neither Xara.app nor the xara command was found (looked in \(ModemLauncher.searchPaths.joined(separator: ", "))). Install xara or set the modem command in Settings."
            case .noAnswer:
                return "Started xara, but nothing answered on the command port within 10 seconds."
            case let .exited(status, tail):
                return "xara exited (status \(status)): \(tail)"
            }
        }
    }
}
#endif
