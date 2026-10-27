import SwiftUI
import WinlinkKit

struct ConnectView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: MailStore
    @EnvironmentObject var session: SessionController

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Transport", selection: Binding(get: { settings.transportKind }, set: { settings.transportKind = $0 })) {
                        Text("VARA (radio)").tag(TransportKind.vara)
                        Text("Telnet (internet)").tag(TransportKind.telnet)
                    }
                    .pickerStyle(.segmented)
                }
                if settings.transportKind == .vara {
                    Section("Gateway") {
                        TextField("RMS call sign, e.g. W1AW-10", text: $settings.gateway)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        if !settings.recentGateways.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(settings.recentGateways, id: \.self) { g in
                                        Button(g) { settings.gateway = g }.buttonStyle(.bordered).font(.caption)
                                    }
                                }
                            }
                        }
                        Picker("Mode", selection: Binding(get: { settings.mode }, set: { settings.mode = $0 })) {
                            Text("VARA HF").tag(VARAMode.hf)
                            Text("VARA FM").tag(VARAMode.fm)
                        }
                        if settings.mode == .hf {
                            Picker("Bandwidth", selection: $settings.bandwidth) {
                                Text("500 Hz").tag("500")
                                Text("2300 Hz").tag("2300")
                                Text("2750 Hz").tag("2750")
                            }
                        }
                    }
                    Section {
                        LabeledContent("Modem", value: "\(settings.modemHost):\(settings.modemPort)")
                        HStack(spacing: 16) {
                            Indicator(label: "PTT", on: session.ptt, color: .red)
                            Indicator(label: "BUSY", on: session.busy, color: .orange)
                            Spacer()
                            Text(stateText).font(.caption).foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Run xara on this phone (or another machine on your network) and point Settings at it. Keep this app open while connected.")
                    }
                } else {
                    Section {
                        LabeledContent("Server", value: "\(settings.cmsHost):\(settings.cmsPort)")
                    } footer: {
                        Text("Telnet goes over the internet straight to the Winlink CMS. No radio involved.")
                    }
                }
                Section {
                    if session.running {
                        Button(role: .destructive) { session.abort() } label: {
                            Label("Abort", systemImage: "xmark.octagon").frame(maxWidth: .infinity)
                        }
                    } else {
                        Button { session.start(settings: settings, store: store) } label: {
                            Label("Connect", systemImage: "antenna.radiowaves.left.and.right").frame(maxWidth: .infinity)
                        }
                        .disabled(settings.mycall.isEmpty)
                    }
                    HStack {
                        if session.running { ProgressView().padding(.trailing, 4) }
                        Text(session.status).font(.callout)
                    }
                    if let p = session.progress {
                        VStack(alignment: .leading) {
                            Text("\(p.sending ? "Sending" : "Receiving") \(p.title)").font(.caption).lineLimit(1)
                            ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                        }
                    }
                    LabeledContent("Outbox", value: "\(store.list(.outbox).count) waiting")
                }
                Section {
                    NavigationLink("Session log (\(session.log.count))") { LogView() }
                }
            }
            .navigationTitle("Connect")
        }
    }

    private var stateText: String {
        switch session.linkState {
        case .closed: return "modem not open"
        case .idle: return "idle"
        case let .connecting(t): return "calling \(t)"
        case let .connected(_, a, w): return "linked \(a) \(w)"
        case .disconnecting: return "disconnecting"
        }
    }
}

struct Indicator: View {
    let label: String
    let on: Bool
    let color: Color
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(on ? color : Color.secondary.opacity(0.3)).frame(width: 10, height: 10)
            Text(label).font(.caption.monospaced())
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(on ? "on" : "off")
    }
}

struct LogView: View {
    @EnvironmentObject var session: SessionController

    var body: some View {
        ScrollViewReader { proxy in
            List(session.log) { l in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(l.time, format: .dateTime.hour().minute().second()).foregroundStyle(.secondary)
                    Text(prefix(l.kind)).foregroundStyle(color(l.kind))
                    Text(l.text).foregroundStyle(color(l.kind)).textSelection(.enabled)
                }
                .font(.caption.monospaced())
                .id(l.id)
            }
            .listStyle(.plain)
            .onChange(of: session.log.count) {
                if let last = session.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .navigationTitle("Session Log")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle("Show modem commands", isOn: $session.showModemTraffic)
                    ShareLink(item: session.log.map { "\($0.time.ISO8601Format()) \(prefix($0.kind)) \($0.text)" }.joined(separator: "\n"))
                    Button("Clear", role: .destructive) { session.clearLog() }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    private func prefix(_ k: LogLine.Kind) -> String {
        switch k {
        case .sent: return ">"
        case .received: return "<"
        case .modemSent: return "»"
        case .modemReceived: return "«"
        case .info: return "·"
        case .error: return "!"
        }
    }

    private func color(_ k: LogLine.Kind) -> Color {
        switch k {
        case .sent: return .blue
        case .received: return .primary
        case .modemSent, .modemReceived: return .secondary
        case .info: return .green
        case .error: return .red
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var password = ""
    @State private var showPassword = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Station") {
                    TextField("Call sign", text: $settings.callsign)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    TextField("Grid locator (e.g. EM10)", text: $settings.locator)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                }
                Section {
                    HStack {
                        Group {
                            if showPassword { TextField("Winlink password", text: $password) } else { SecureField("Winlink password", text: $password) }
                        }
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { settings.password = password }
                        Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye") }
                            .buttonStyle(.borderless)
                    }
                    Button("Save password") { settings.password = password }.disabled(password == settings.password)
                } header: {
                    Text("Winlink account")
                } footer: {
                    Text("Stored in the iOS Keychain on this device only. Used to answer the gateway's secure login challenge; the password itself is never sent.")
                }
                Section {
                    TextField("Host", text: $settings.modemHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Command port", value: $settings.modemPort, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                    LabeledContent("Data port", value: "\(settings.modemPort + 1)")
                } header: {
                    Text("VARA modem")
                } footer: {
                    Text("127.0.0.1 is xara running on this phone. Use a LAN address for xara or VARA on another computer.")
                }
                Section("Winlink CMS (telnet)") {
                    TextField("Host", text: $settings.cmsHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Port", value: $settings.cmsPort, format: .number.grouping(.never)).keyboardType(.numberPad)
                }
                Section {
                    Text("XaraMail \(Bundle.main.shortVersion). B2F protocol code ported from wl2k-go by Martin Hebnes Pedersen (LA5NTA), MIT licence.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .onAppear { password = settings.password }
            .onChange(of: settings.callsign) { password = settings.password }
        }
    }
}
