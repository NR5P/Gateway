import SwiftUI
import WinlinkKit

struct ConnectView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: MailStore
    @EnvironmentObject var session: SessionController
    @EnvironmentObject var rig: RigController

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Connect to", selection: Binding(get: { settings.transportKind }, set: { settings.transportKind = $0 })) {
                        Text("RMS gateway (VARA)").tag(TransportKind.vara)
                        Text("Station, P2P (VARA)").tag(TransportKind.p2p)
                        Text("Listen for P2P calls").tag(TransportKind.listen)
                        Text("Terminal: BBS, node or chat").tag(TransportKind.terminal)
                        Text("Telnet (internet)").tag(TransportKind.telnet)
                    }
                    .disabled(session.running)
                } footer: {
                    Text(kindHelp)
                }
                if settings.transportKind.usesRadio {
                    Section(settings.transportKind == .vara ? "RMS gateway" : "Station") {
                        switch settings.transportKind {
                        case .vara:
                            TextField("RMS call sign, e.g. W1AW-10", text: $settings.gateway)
                                .input(.callsign)
                            if !settings.recentGateways.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack {
                                        ForEach(settings.recentGateways, id: \.self) { g in
                                            Button(g) { settings.select(gateway: g) }.buttonStyle(.bordered).font(.caption)
                                        }
                                    }
                                }
                            }
                        case .p2p:
                            TextField("Their call sign", text: $settings.peer).input(.callsign)
                        case .terminal:
                            Toggle("Wait for a call", isOn: $settings.terminalAnswer)
                            if !settings.terminalAnswer {
                                TextField("Call sign of the BBS, node or station", text: $settings.peer).input(.callsign)
                            }
                        default:
                            LabeledContent("Answering as", value: settings.mycall.isEmpty ? "—" : settings.mycall)
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
                    if settings.rigMode != .off {
                        RadioSection()
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
                        #if os(macOS)
                        Text("Gateway starts xara on this Mac if it is not running. Or point Settings at a modem elsewhere on your network.")
                        #else
                        Text("Run xara on this phone (or another machine on your network) and point Settings at it. Keep this app open while connected.")
                        #endif
                    }
                } else {
                    Section {
                        LabeledContent("Server", value: "\(settings.cmsHost):\(settings.cmsPort)")
                    } footer: {
                        Text("Telnet goes over the internet straight to the Winlink CMS. No radio involved.")
                    }
                }
                if settings.transportKind == .terminal {
                    TerminalSection()
                }
                Section {
                    if session.running {
                        if session.terminalLinked {
                            Button { session.hangUp() } label: {
                                Label("Disconnect", systemImage: "phone.down").frame(maxWidth: .infinity)
                            }
                        }
                        Button(role: .destructive) { session.abort() } label: {
                            Label(listening ? "Stop listening" : "Abort", systemImage: "xmark.octagon").frame(maxWidth: .infinity)
                        }
                    } else {
                        Button { session.start(settings: settings, store: store, rig: rig) } label: {
                            Label(listening ? "Listen" : "Connect", systemImage: listening ? "ear" : "antenna.radiowaves.left.and.right").frame(maxWidth: .infinity)
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
            .groupedForm()
            .navigationTitle("Connect")
        }
    }

    private var listening: Bool {
        settings.transportKind == .listen || (settings.transportKind == .terminal && settings.terminalAnswer)
    }

    private var kindHelp: String {
        switch settings.transportKind {
        case .vara: return "Sends your Outbox and downloads your mail through a gateway. Find one on the Stations tab."
        case .p2p: return "Swaps messages straight with another station, no gateway or internet: only mail addressed to their call sign goes."
        case .listen: return "Waits for other stations to call you P2P and swaps messages with each caller until you stop."
        case .terminal: return "Type to a packet BBS or BPQ node, or chat with another operator who is listening in Terminal mode."
        case .telnet: return "Over the internet straight to the Winlink CMS. No radio involved."
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

/// Dial frequency, what the radio is doing, and the tuner.
struct RadioSection: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var session: SessionController
    @EnvironmentObject var rig: RigController

    var body: some View {
        Section {
            TextField("Dial frequency, kHz (e.g. 14105.0)", text: $settings.dialFrequency)
                .input(.plain)
            if let name = rig.connected {
                HStack(spacing: 12) {
                    Text(rig.status.frequency.map(DialFrequency.format) ?? "—").font(.body.monospacedDigit())
                    Text(rig.status.mode ?? "").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Indicator(label: "TX", on: rig.status.transmitting, color: .red)
                }
                .accessibilityLabel("Radio \(name)")
                HStack {
                    Button("Set frequency") {
                        Task {
                            guard let hz = DialFrequency.parse(settings.dialFrequency) else { return }
                            try? await rig.prepare(settings: settings, frequency: hz, mode: settings.mode == .fm ? .dataFM : .dataUSB)
                        }
                    }
                    .disabled(DialFrequency.parse(settings.dialFrequency) == nil || session.running)
                    Spacer()
                    Button { Task { await rig.tune(settings: settings) } } label: { Label("Tune", systemImage: "dial.medium") }
                        .disabled(session.running)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    Task { try? await rig.open(settings: settings) }
                } label: {
                    HStack {
                        Label(rig.scanning ? "Looking for the radio…" : "Find radio", systemImage: "magnifyingglass")
                        if rig.scanning { Spacer(); ProgressView() }
                    }
                }
                .disabled(rig.scanning)
            }
            if !rig.message.isEmpty {
                Text(rig.message).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Radio")
        } footer: {
            Text(rig.connected.map { "\($0). Gateway sets the frequency\(settings.rigSetDataMode ? " and data mode" : "") before calling\(settings.rigKeysPTT ? " and keys the radio when the modem transmits" : "")." }
                 ?? "Finds RigHelm on this device or your network, or a rigctld. Leave the frequency empty to call on whatever the radio is tuned to.")
        }
    }
}

struct TerminalSection: View {
    @EnvironmentObject var session: SessionController
    @State private var line = ""

    var body: some View {
        Section("Terminal") {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(session.terminal.isEmpty ? "Nothing yet." : session.terminal)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(minHeight: 180, maxHeight: 320)
                .onChange(of: session.terminal) { proxy.scrollTo("end", anchor: .bottom) }
            }
            HStack {
                TextField(session.terminalLinked ? "Type and press Return" : "Not connected", text: $line)
                    .input(.plain)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "paperplane.fill") }
                    .buttonStyle(.borderless)
            }
            .disabled(!session.terminalLinked)
        }
    }

    private func send() {
        guard session.terminalLinked else { return }
        session.sendTerminal(line)
        line = ""
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
                        .input(.callsign)
                    TextField("Grid locator (e.g. EM10)", text: $settings.locator)
                        .input(.callsign)
                }
                Section {
                    HStack {
                        Group {
                            if showPassword { TextField("Winlink password", text: $password) } else { SecureField("Winlink password", text: $password) }
                        }
                        .input(.plain)
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
                RigSettingsSection()
                Section {
                    TextField("Host", text: $settings.modemHost)
                        .input(.url)
                    TextField("Command port", value: $settings.modemPort, format: .number.grouping(.never))
                        .input(.number)
                    LabeledContent("Data port", value: "\(settings.modemPort + 1)")
                } header: {
                    Text("VARA modem")
                } footer: {
                    #if os(macOS)
                    Text("127.0.0.1 is xara on this Mac. Use a LAN address for xara (or VARA) on another machine, such as the xara iPhone app with local-network clients allowed.")
                    #else
                    Text("127.0.0.1 is xara running on this phone. Use a LAN address for xara or VARA on another computer.")
                    #endif
                }
                #if os(macOS)
                Section {
                    TextField("Command", text: $settings.modemCommand, axis: .vertical)
                        .font(.body.monospaced()).input(.plain)
                    Toggle("Stop xara when Gateway quits", isOn: $settings.stopModemOnQuit)
                    Button("Reset to default") { settings.modemCommand = ModemLauncher.defaultCommandLine }
                } header: {
                    Text("Start xara automatically")
                } footer: {
                    Text("When the modem host is 127.0.0.1 and nothing answers, Gateway opens Xara.app (xara://start) or, if it is not installed, runs this command. {call} and {port} are filled in; name your radio's audio interface (xara --list-devices). Output goes to ~/Library/Logs/Gateway/xara.log.")
                }
                #endif
                APIKeySection()
                Section("Winlink CMS (telnet)") {
                    TextField("Host", text: $settings.cmsHost)
                        .input(.url)
                    TextField("Port", value: $settings.cmsPort, format: .number.grouping(.never)).input(.number)
                }
                Section {
                    Text("Gateway \(Bundle.main.shortVersion). B2F protocol code ported from wl2k-go by Martin Hebnes Pedersen (LA5NTA), MIT licence.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .groupedForm()
            .navigationTitle("Settings")
            .onAppear { password = settings.password }
            .onChange(of: settings.callsign) { password = settings.password }
        }
    }
}

struct RigSettingsSection: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var rig: RigController
    @State private var password = ""

    var body: some View {
        Section {
            Picker("Radio control", selection: Binding(get: { settings.rigMode }, set: {
                settings.rigMode = $0
                if $0 == .righelm { settings.rigPort = Int(RigHelmRig.defaultPort) }
                if $0 == .rigctld { settings.rigPort = Int(RigctldRig.defaultPort) }
                rig.disconnect()
            })) {
                ForEach(RigControlMode.allCases) { Text($0.label).tag($0) }
            }
            if settings.rigMode == .righelm || settings.rigMode == .rigctld {
                TextField("Host", text: $settings.rigHost).input(.url)
                TextField("Port", value: $settings.rigPort, format: .number.grouping(.never)).input(.number)
            }
            if settings.rigMode == .auto {
                ForEach(rig.endpoints) { e in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(e.title)
                            Text(e.kind == .righelm
                                 ? "\(e.host):\(e.port) · radio \(e.radio)" + (e.auth ? "" : " · receive only (no password)")
                                 : e.host == "127.0.0.1" ? "hamlib, on this device" : "hamlib")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if e.id == settings.rigLastEndpoint { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        settings.rigLastEndpoint = e.id
                        rig.disconnect()
                    }
                }
                Button(rig.scanning ? "Searching…" : "Search for radios") { Task { await rig.scan(settings: settings) } }
                    .disabled(rig.scanning)
            }
            if settings.rigMode != .off {
                if settings.rigMode != .rigctld {
                    SecureField("RigHelm password", text: $password)
                        .input(.plain)
                        .onSubmit { settings.rigPassword = password; rig.disconnect() }
                    Button("Save RigHelm password") { settings.rigPassword = password; rig.disconnect() }
                        .disabled(password == settings.rigPassword)
                }
                Toggle("Key the radio when the modem transmits", isOn: $settings.rigKeysPTT)
                Toggle("Set data mode (DATA-U / DATA-FM)", isOn: $settings.rigSetDataMode)
            }
        } header: {
            Text("Radio control")
        } footer: {
            #if os(macOS)
            Text("Run RigHelm on this Mac (it finds the radio on USB) or on the computer the radio is plugged into; Gateway finds it. rigctld works too. Transmitting through RigHelm needs its password and remote transmit allowed. Turn off keying if xara keys the radio itself (--ptt rts/cm108/rigctld).")
            #else
            Text("iOS gives apps no USB serial access, so the radio is reached over the network: RigHelm on the computer it is plugged into (found automatically), or rigctld. Transmitting through RigHelm needs its password and remote transmit allowed. Turn off keying if the modem keys the radio itself.")
            #endif
        }
        .onAppear {
            password = settings.rigPassword
            if settings.rigMode == .auto && rig.endpoints.isEmpty { Task { await rig.scan(settings: settings) } }
        }
    }
}

struct APIKeySection: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var gateways: GatewayStore
    @State private var key = ""

    var body: some View {
        Section {
            SecureField("Winlink API key", text: $key)
                .input(.plain)
                .onSubmit { settings.winlinkAPIKey = key }
            Toggle("Update automatically (daily)", isOn: $settings.gatewayAutoUpdate)
            Button {
                settings.winlinkAPIKey = key
                Task { await gateways.refresh(key: key) }
            } label: {
                HStack {
                    Text("Update now")
                    if gateways.refreshing { Spacer(); ProgressView() }
                }
            }
            .disabled(key.isEmpty || gateways.refreshing)
            if !gateways.message.isEmpty { Text(gateways.message).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("Gateway list")
        } footer: {
            Text((gateways.downloaded
                  ? "\(gateways.gateways.count) VARA gateways, downloaded \(gateways.updated?.formatted(date: .abbreviated, time: .shortened) ?? "")"
                  : "\(gateways.gateways.count) VARA gateways from the list built into the app (\(gateways.updated?.formatted(date: .abbreviated, time: .omitted) ?? ""))")
                 + ". The last list downloaded is kept on this device, so Stations works with no internet. Downloading from api.winlink.org needs an API key, which the Winlink Development Team issues for each program: ask them for one and enter it here.")
        }
        .onAppear { key = settings.winlinkAPIKey }
    }
}
