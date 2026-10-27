import SwiftUI

@main
struct GatewayApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var store = MailStore()
    @StateObject private var session = SessionController()

    var body: some Scene {
        WindowGroup {
            TabView {
                MailboxView()
                    .tabItem { Label("Mail", systemImage: "envelope") }
                    .badge(store.unreadCount)
                ConnectView()
                    .tabItem { Label("Connect", systemImage: "antenna.radiowaves.left.and.right") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gear") }
            }
            #if DEBUG
            .task {
                // Test hook: `-autoConnect` starts a session with the saved settings at launch.
                if ProcessInfo.processInfo.arguments.contains("-autoConnect") {
                    session.start(settings: settings, store: store)
                }
            }
            #endif
            .environmentObject(settings)
            .environmentObject(store)
            .environmentObject(session)
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 560)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                // Other clients may share the modem, so it keeps running unless asked otherwise.
                if settings.stopModemOnQuit { ModemLauncher.shared.stopIfStarted() }
            }
            #endif
        }
    }
}
