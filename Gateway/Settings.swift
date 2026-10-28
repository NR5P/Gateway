import Foundation
import Security
import SwiftUI
import WinlinkKit

enum TransportKind: String, CaseIterable, Identifiable {
    /// Call an RMS gateway.
    case vara = "VARA"
    /// Call another station directly (peer to peer) and swap messages.
    case p2p = "P2P"
    /// Wait for P2P calls and swap messages.
    case listen = "Listen"
    /// Keyboard to keyboard: a BBS, node or chat with another operator.
    case terminal = "Terminal"
    case telnet = "Telnet"
    var id: String { rawValue }
    var usesRadio: Bool { self != .telnet }
}

enum RigControlMode: String, CaseIterable, Identifiable {
    case off, auto, righelm, rigctld
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .auto: return "Automatic"
        case .righelm: return "RigHelm"
        case .rigctld: return "rigctld (hamlib)"
        }
    }
}

/// Station and modem settings, kept in UserDefaults; the Winlink password lives in the Keychain.
final class AppSettings: ObservableObject {
    @AppStorage("callsign") var callsign = ""
    @AppStorage("locator") var locator = ""
    @AppStorage("transport") var transport = TransportKind.vara.rawValue
    @AppStorage("gateway") var gateway = ""
    /// The station to call for P2P or a terminal session.
    @AppStorage("peer") var peer = ""
    /// Terminal: wait for a call instead of calling.
    @AppStorage("terminalAnswer") var terminalAnswer = false
    @AppStorage("varaMode") var varaMode = VARAMode.hf.rawValue
    @AppStorage("bandwidth") var bandwidth = "2300"
    @AppStorage("modemHost") var modemHost = "127.0.0.1"
    @AppStorage("modemPort") var modemPort = 8300
    @AppStorage("cmsHost") var cmsHost = CMSTelnet.host
    @AppStorage("cmsPort") var cmsPort = Int(CMSTelnet.port)
    @AppStorage("recentGateways") private var recentGatewaysRaw = ""
    /// The dial frequency to call on, as typed (kHz or MHz).
    @AppStorage("dialFrequency") var dialFrequency = ""
    /// "CALL=hz" pairs: the frequency last used for each gateway.
    @AppStorage("gatewayFrequencies") private var gatewayFrequenciesRaw = ""
    @AppStorage("rigControl") var rigControl = RigControlMode.auto.rawValue
    @AppStorage("rigHost") var rigHost = "127.0.0.1"
    @AppStorage("rigPort") var rigPort = Int(RigHelmRig.defaultPort)
    @AppStorage("rigLastEndpoint") var rigLastEndpoint = ""
    /// Key the transmitter over CAT when the modem says PTT ON (off if the modem keys it itself).
    @AppStorage("rigKeysPTT") var rigKeysPTT = true
    @AppStorage("rigSetDataMode") var rigSetDataMode = true
    /// Download the gateway list once a day when an API key is set.
    @AppStorage("gatewayAutoUpdate") var gatewayAutoUpdate = true
    #if os(macOS)
    /// How to start the xara command when no modem answers locally and Xara.app is not installed.
    @AppStorage("modemCommand") var modemCommand = ModemLauncher.defaultCommandLine
    @AppStorage("stopModemOnQuit") var stopModemOnQuit = false
    #endif

    var mycall: String { callsign.trimmingCharacters(in: .whitespaces).uppercased() }

    var transportKind: TransportKind {
        get { TransportKind(rawValue: transport) ?? .vara }
        set { transport = newValue.rawValue }
    }

    var mode: VARAMode {
        get { VARAMode(rawValue: varaMode) ?? .hf }
        set { varaMode = newValue.rawValue }
    }

    var rigMode: RigControlMode {
        get { RigControlMode(rawValue: rigControl) ?? .auto }
        set { rigControl = newValue.rawValue }
    }

    var recentGateways: [String] {
        recentGatewaysRaw.split(separator: ",").map(String.init)
    }

    func remember(gateway g: String) {
        var list = recentGateways.filter { $0 != g }
        list.insert(g, at: 0)
        recentGatewaysRaw = list.prefix(8).joined(separator: ",")
    }

    func frequency(for gateway: String) -> Int? {
        for pair in gatewayFrequenciesRaw.split(separator: ",") {
            let kv = pair.split(separator: "=")
            if kv.count == 2, kv[0] == gateway { return Int(kv[1]) }
        }
        return nil
    }

    func remember(frequency hz: Int, for gateway: String) {
        var pairs = gatewayFrequenciesRaw.split(separator: ",").map(String.init).filter { !$0.hasPrefix(gateway + "=") }
        pairs.insert("\(gateway)=\(hz)", at: 0)
        gatewayFrequenciesRaw = pairs.prefix(40).joined(separator: ",")
    }

    /// Picks a gateway, with the frequency last used for it.
    func select(gateway g: String, frequency hz: Int? = nil) {
        gateway = g
        if let f = hz ?? frequency(for: g) { dialFrequency = String(format: "%.1f", Double(f) / 1000) }
    }

    /// Key for api.winlink.org (issued per program by the Winlink Development Team), in the Keychain.
    var winlinkAPIKey: String {
        get { Keychain.read(account: "api", service: Keychain.apiService) ?? "" }
        set {
            objectWillChange.send()
            if newValue.isEmpty { Keychain.delete(account: "api", service: Keychain.apiService) } else { Keychain.write(newValue, account: "api", service: Keychain.apiService) }
        }
    }

    /// RigHelm station password (only needed to transmit), in the Keychain.
    var rigPassword: String {
        get { Keychain.read(account: "rig", service: Keychain.rigService) ?? "" }
        set {
            objectWillChange.send()
            if newValue.isEmpty { Keychain.delete(account: "rig", service: Keychain.rigService) } else { Keychain.write(newValue, account: "rig", service: Keychain.rigService) }
        }
    }

    var password: String {
        get { Keychain.read(account: mycall) ?? "" }
        set {
            objectWillChange.send()
            if newValue.isEmpty { Keychain.delete(account: mycall) } else { Keychain.write(newValue, account: mycall) }
        }
    }
}

/// Generic-password Keychain items, one per call sign.
enum Keychain {
    static let service = "Winlink password"
    static let rigService = "RigHelm password"
    static let apiService = "Winlink API key"

    private static func query(_ account: String, _ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(account: String, service: String = service) -> String? {
        guard !account.isEmpty else { return nil }
        var q = query(account, service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func write(_ value: String, account: String, service: String = service) {
        guard !account.isEmpty else { return }
        let data = Data(value.utf8)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query(account, service) as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var q = query(account, service)
            q.merge(attrs) { $1 }
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    static func delete(account: String, service: String = service) {
        SecItemDelete(query(account, service) as CFDictionary)
    }
}
