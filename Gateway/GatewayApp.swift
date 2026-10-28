import SwiftUI

@main
struct GatewayApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var store = MailStore()
    @StateObject private var session = SessionController()
    @StateObject private var rig = RigController()
    @StateObject private var gateways = GatewayStore()
    @StateObject private var nav = AppNavigation()

    var body: some Scene {
        WindowGroup {
            TabView(selection: $nav.tab) {
                MailboxView()
                    .tabItem { Label("Mail", systemImage: "envelope") }
                    .badge(store.unreadCount)
                    .tag(AppTab.mail)
                StationsView()
                    .tabItem { Label("Stations", systemImage: "map") }
                    .tag(AppTab.stations)
                ConnectView()
                    .tabItem { Label("Connect", systemImage: "antenna.radiowaves.left.and.right") }
                    .tag(AppTab.connect)
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gear") }
                    .tag(AppTab.settings)
            }
            #if DEBUG
            .task {
                // Test hook: `-autoConnect` starts a session with the saved settings at launch.
                if ProcessInfo.processInfo.arguments.contains("-autoConnect") {
                    session.start(settings: settings, store: store, rig: rig)
                }
            }
            #endif
            .environmentObject(settings)
            .environmentObject(store)
            .environmentObject(session)
            .environmentObject(rig)
            .environmentObject(gateways)
            .environmentObject(nav)
            .task {
                rig.log = { [weak session] kind, text in session?.append(kind, text) }
                await gateways.refreshIfDue(settings: settings)
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 560)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                // Other clients may share the modem, so it keeps running unless asked otherwise.
                if settings.stopModemOnQuit { ModemLauncher.shared.stopIfStarted() }
                rig.disconnect()
            }
            #endif
        }
    }
}
