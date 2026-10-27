import SwiftUI

@main
struct XaraMailApp: App {
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
            .environmentObject(settings)
            .environmentObject(store)
            .environmentObject(session)
        }
    }
}
