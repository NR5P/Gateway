import MapKit
import SwiftUI
import WinlinkKit

/// The RMS gateway list: the copy bundled with the app, or a newer download kept in
/// Application Support (downloading needs a Winlink API key, see Settings).
@MainActor
final class GatewayStore: ObservableObject {
    @Published private(set) var gateways: [RMSGateway] = []
    @Published private(set) var updated: Date?
    @Published private(set) var refreshing = false
    /// The list came from api.winlink.org (not the copy bundled with the app).
    @Published private(set) var downloaded = false
    @Published var message = ""

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("gateways.json")
    }

    init() {
        if let d = try? Data(contentsOf: cacheURL), let g = try? GatewayDirectory.parse(d), !g.isEmpty {
            gateways = g
            updated = (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            downloaded = true
        } else if let url = Bundle.main.url(forResource: "gateways", withExtension: "json"),
                  let d = try? Data(contentsOf: url), let g = try? GatewayDirectory.parse(d) {
            gateways = g
            updated = g.compactMap(\.lastStatus).max()
        }
    }

    func refresh(key: String) async {
        guard !key.isEmpty else {
            message = "Add a Winlink API key in Settings to download the current list."
            return
        }
        refreshing = true
        defer { refreshing = false }
        do {
            let data = try await GatewayDirectory.fetch(key: key)
            gateways = try GatewayDirectory.parse(data)
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL)
            updated = Date()
            downloaded = true
            message = ""
        } catch {
            // The saved list stays in use, so this works offline.
            message = "Download failed: \(error.localizedDescription)"
        }
    }

    /// Downloads when auto-update is on and the saved list is over a day old (or bundled).
    func refreshIfDue(settings: AppSettings) async {
        let key = settings.winlinkAPIKey
        guard settings.gatewayAutoUpdate, !key.isEmpty, !refreshing else { return }
        if downloaded, let u = updated, Date().timeIntervalSince(u) < 24 * 3600 { return }
        await refresh(key: key)
    }
}

enum AppTab: Hashable { case mail, stations, connect, settings }

@MainActor
final class AppNavigation: ObservableObject {
    @Published var tab: AppTab = .mail
}

enum StationFilter: String, CaseIterable, Identifiable {
    case hf = "VARA HF", fm = "VARA FM", all = "All"
    var id: String { rawValue }
}

struct StationsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var gateways: GatewayStore
    @State private var showList = false
    @State private var filter = StationFilter.hf
    @State private var band = "Any band"
    @State private var search = ""
    @State private var selected: RMSGateway?
    @State private var region: MKCoordinateRegion?
    @State private var position: MapCameraPosition = .automatic

    private var home: (lat: Double, lon: Double)? { Maidenhead.coordinate(settings.locator.trimmingCharacters(in: .whitespaces)) }

    private func channels(_ g: RMSGateway) -> [RMSChannel] {
        g.channels.filter { c in
            (filter == .all || (filter == .fm) == c.isFM) && (band == "Any band" || c.band == band)
        }
    }

    private var matching: [RMSGateway] {
        let q = search.trimmingCharacters(in: .whitespaces).uppercased()
        return gateways.gateways.filter { !channels($0).isEmpty && (q.isEmpty || $0.callsign.contains(q)) }
    }

    private var sorted: [RMSGateway] {
        guard let home else { return matching.sorted { $0.callsign < $1.callsign } }
        return matching.sorted { distance($0, from: home) < distance($1, from: home) }
    }

    private func distance(_ g: RMSGateway, from h: (lat: Double, lon: Double)) -> Double {
        Maidenhead.distance(h, (g.latitude, g.longitude))
    }

    /// Markers in view, at most a few hundred (nearest the middle of the map first).
    private var onMap: [RMSGateway] {
        guard let r = region else { return Array(sorted.prefix(300)) }
        let c = r.center, s = r.span
        let inView = matching.filter {
            abs($0.latitude - c.latitude) <= s.latitudeDelta / 2
                && abs((($0.longitude - c.longitude + 540).truncatingRemainder(dividingBy: 360)) - 180) <= s.longitudeDelta / 2
        }
        guard inView.count > 300 else { return inView }
        return Array(inView.sorted {
            Maidenhead.distance((c.latitude, c.longitude), ($0.latitude, $0.longitude))
                < Maidenhead.distance((c.latitude, c.longitude), ($1.latitude, $1.longitude))
        }.prefix(300))
    }

    private var bands: [String] {
        let all = Set(gateways.gateways.flatMap { $0.channels.filter { filter == .all || (filter == .fm) == $0.isFM }.map(\.band) })
        return ["Any band"] + all.sorted { (Double($0.dropLast(1)) ?? 0) > (Double($1.dropLast(1)) ?? 0) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if showList { list } else { map }
            }
            .navigationTitle("Stations")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Picker("View", selection: $showList) {
                        Image(systemName: "map").tag(false)
                        Image(systemName: "list.bullet").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Picker("Mode", selection: $filter) {
                            ForEach(StationFilter.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Band", selection: $band) {
                            ForEach(bands, id: \.self) { Text($0).tag($0) }
                        }
                        Divider()
                        Button { Task { await gateways.refresh(key: settings.winlinkAPIKey) } } label: {
                            Label("Update now", systemImage: "arrow.clockwise")
                        }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                }
            }
            .onChange(of: filter) { band = "Any band" }
            .task { await gateways.refreshIfDue(settings: settings) }
            .sheet(item: $selected) { g in
                StationDetail(gateway: g, channels: channels(g), home: home)
                    #if os(macOS)
                    .frame(minWidth: 420, minHeight: 380)
                    #endif
            }
        }
    }

    private var map: some View {
        Map(position: $position) {
            if let home {
                Annotation("You", coordinate: CLLocationCoordinate2D(latitude: home.lat, longitude: home.lon)) {
                    Image(systemName: "house.circle.fill").font(.title2).foregroundStyle(.white, .blue)
                }
            }
            ForEach(onMap) { g in
                Annotation(g.callsign, coordinate: CLLocationCoordinate2D(latitude: g.latitude, longitude: g.longitude)) {
                    Button { selected = g } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, channels(g).contains(where: \.isFM) && filter != .hf ? .purple : .teal)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Gateway \(g.callsign)")
                }
            }
        }
        .mapControls {
            #if os(macOS)
            MapZoomStepper()
            #endif
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { region = $0.region }
        .onAppear {
            if let home, region == nil {
                position = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: home.lat, longitude: home.lon),
                                                      span: MKCoordinateSpan(latitudeDelta: 18, longitudeDelta: 24)))
            }
        }
        .overlay(alignment: .bottom) { footer.padding(8) }
    }

    private var footer: some View {
        VStack(spacing: 2) {
            Text("\(matching.count) gateways · \(filter.rawValue)\(band == "Any band" ? "" : " · \(band)")")
            if let u = gateways.updated {
                Text("\(gateways.downloaded ? "Updated" : "Built-in list from") \(u.formatted(date: .abbreviated, time: gateways.downloaded ? .shortened : .omitted))")
            }
            if !gateways.message.isEmpty { Text(gateways.message).foregroundStyle(.red) }
            if gateways.refreshing { ProgressView() }
            if home == nil { Text("Set your grid locator in Settings to sort by distance.") }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var list: some View {
        List(sorted) { g in
            Button { selected = g } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(g.callsign).font(.headline)
                        Text(channels(g).map { "\($0.band) \(DialFrequency.format($0.dial))" }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if let home {
                        VStack(alignment: .trailing) {
                            Text("\(Int(distance(g, from: home))) km").font(.callout.monospacedDigit())
                            Text("\(Int(Maidenhead.bearing(home, (g.latitude, g.longitude))))°").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .searchable(text: $search, prompt: "Call sign")
        .overlay(alignment: .bottom) { footer.padding(8) }
    }
}

struct StationDetail: View {
    let gateway: RMSGateway
    let channels: [RMSChannel]
    let home: (lat: Double, lon: Double)?
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: MailStore
    @EnvironmentObject var session: SessionController
    @EnvironmentObject var rig: RigController
    @EnvironmentObject var nav: AppNavigation
    @Environment(\.dismiss) private var dismiss
    @State private var tuning: String?
    @State private var tuned: String?
    @State private var tuneError = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let home {
                        let to = (gateway.latitude, gateway.longitude)
                        LabeledContent("Distance", value: "\(Int(Maidenhead.distance(home, to))) km, \(Int(Maidenhead.bearing(home, to)))°")
                    }
                    if let g = channels.first?.grid, !g.isEmpty { LabeledContent("Grid", value: g) }
                    if let s = gateway.lastStatus { LabeledContent("Last heard by the CMS", value: s.formatted(date: .abbreviated, time: .shortened)) }
                    if !gateway.comments.isEmpty { Text(gateway.comments).font(.callout) }
                }
                Section {
                    ForEach(channels) { c in
                        HStack {
                            if tuning == c.id {
                                ProgressView()
                            } else {
                                Image(systemName: tuned == c.id ? "dot.radiowaves.left.and.right" : "dial.medium")
                                    .foregroundStyle(tuned == c.id ? Color.accentColor : .secondary)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(DialFrequency.format(c.dial)) MHz").font(.body.monospacedDigit())
                                Text("\(c.band) · \(c.modes) · \(c.hours.isEmpty ? "" : "\(c.hours) UTC")\(c.antenna.isEmpty ? "" : " · \(c.antenna)")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Connect") { connect(c) }
                                .buttonStyle(.borderedProminent)
                                .disabled(session.running || settings.mycall.isEmpty)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { tune(c) }
                        .accessibilityAction(named: "Tune the radio") { tune(c) }
                    }
                } header: {
                    Text("Channels (dial frequency)")
                } footer: {
                    if !tuneError.isEmpty { Text(tuneError).foregroundStyle(.red) }
                    Text("Tap a channel to tune the radio to it. " + (settings.mycall.isEmpty ? "Set your call sign in Settings first." : settings.rigMode == .off
                         ? "Radio control is off: tune the radio to the dial frequency yourself before connecting."
                         : "Connect tunes the radio, sets the data mode and calls \(gateway.callsign)."))
                }
            }
            .navigationTitle(gateway.callsign)
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }

    /// Makes this channel the one to call, and moves the radio to it.
    private func choose(_ c: RMSChannel) {
        settings.transportKind = .vara
        settings.select(gateway: gateway.callsign, frequency: c.dial)
        settings.mode = c.isFM ? .fm : .hf
        if let bw = c.bandwidth { settings.bandwidth = bw }
    }

    private func tune(_ c: RMSChannel) {
        guard !session.running, tuning == nil else { return }
        choose(c)
        tuneError = ""
        guard settings.rigMode != .off else {
            tuneError = "Radio control is off (Settings): tune to \(DialFrequency.format(c.dial)) yourself."
            return
        }
        tuning = c.id
        Task {
            defer { tuning = nil }
            do {
                try await rig.prepare(settings: settings, frequency: c.dial, mode: c.isFM ? .dataFM : .dataUSB)
                tuned = c.id
            } catch {
                tuned = nil
                tuneError = "Could not tune the radio: \(error.localizedDescription)"
            }
        }
    }

    private func connect(_ c: RMSChannel) {
        choose(c)
        dismiss()
        nav.tab = .connect
        session.start(settings: settings, store: store, rig: rig)
    }
}
