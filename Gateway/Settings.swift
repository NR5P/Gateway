import Foundation
import Security
import SwiftUI
import WinlinkKit

enum TransportKind: String, CaseIterable, Identifiable {
    case vara = "VARA"
    case telnet = "Telnet"
    var id: String { rawValue }
}

/// Station and modem settings, kept in UserDefaults; the Winlink password lives in the Keychain.
final class AppSettings: ObservableObject {
    @AppStorage("callsign") var callsign = ""
    @AppStorage("locator") var locator = ""
    @AppStorage("transport") var transport = TransportKind.vara.rawValue
    @AppStorage("gateway") var gateway = ""
    @AppStorage("varaMode") var varaMode = VARAMode.hf.rawValue
    @AppStorage("bandwidth") var bandwidth = "2300"
    @AppStorage("modemHost") var modemHost = "127.0.0.1"
    @AppStorage("modemPort") var modemPort = 8300
    @AppStorage("cmsHost") var cmsHost = CMSTelnet.host
    @AppStorage("cmsPort") var cmsPort = Int(CMSTelnet.port)
    @AppStorage("recentGateways") private var recentGatewaysRaw = ""
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

    var recentGateways: [String] {
        recentGatewaysRaw.split(separator: ",").map(String.init)
    }

    func remember(gateway g: String) {
        var list = recentGateways.filter { $0 != g }
        list.insert(g, at: 0)
        recentGatewaysRaw = list.prefix(8).joined(separator: ",")
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
    private static let service = "Winlink password"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(account: String) -> String? {
        guard !account.isEmpty else { return nil }
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        guard !account.isEmpty else { return }
        let data = Data(value.utf8)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query(account) as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var q = query(account)
            q.merge(attrs) { $1 }
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
