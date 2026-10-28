import CoreLocation
import SwiftUI
import WinlinkKit

/// Puts a position report in the Outbox: a message to QTH that shows this station on the
/// Winlink map once it is sent.
struct PositionReportView: View {
    @EnvironmentObject var store: MailStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var locator = OneShotLocation()
    @State private var lat = ""
    @State private var lon = ""
    @State private var comment = ""
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Latitude (e.g. 30.2672)", text: $lat).input(.plain)
                    TextField("Longitude (e.g. -97.7431)", text: $lon).input(.plain)
                    Button {
                        locator.request()
                    } label: {
                        HStack {
                            Label("Use this device's location", systemImage: "location")
                            if locator.busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(locator.busy)
                    if !locator.message.isEmpty { Text(locator.message).font(.caption).foregroundStyle(.secondary) }
                } header: {
                    Text("Position")
                } footer: {
                    Text("Decimal degrees: south and west are negative. Filled in from your grid locator, which is only accurate to tens of km.")
                }
                Section("Comment (up to 80 characters)") {
                    TextField("e.g. QRV 145.500", text: $comment).input(.plain)
                }
                if !error.isEmpty {
                    Text(error).foregroundStyle(.red)
                }
            }
            .groupedForm()
            .navigationTitle("Position Report")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Post", action: post).bold() }
            }
            .onAppear {
                if let c = Maidenhead.coordinate(settings.locator.trimmingCharacters(in: .whitespaces)) {
                    lat = String(format: "%.4f", c.lat)
                    lon = String(format: "%.4f", c.lon)
                }
            }
            .onChange(of: locator.coordinate?.latitude) {
                if let c = locator.coordinate {
                    lat = String(format: "%.5f", c.latitude)
                    lon = String(format: "%.5f", c.longitude)
                }
            }
        }
    }

    private func post() {
        guard !settings.mycall.isEmpty else { error = "Set your call sign in Settings first."; return }
        guard let la = Double(lat), let lo = Double(lon), abs(la) <= 90, abs(lo) <= 180 else {
            error = "Enter a latitude (-90 to 90) and longitude (-180 to 180)."
            return
        }
        do {
            try store.save(PositionReport(latitude: la, longitude: lo, comment: comment).message(from: settings.mycall), to: .outbox)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

@MainActor
final class OneShotLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func request() {
        busy = true
        message = ""
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in
            guard busy else { return }
            switch m.authorizationStatus {
            case .notDetermined: break
            case .denied, .restricted:
                busy = false
                message = "Location access is off for Gateway."
            default: m.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            coordinate = locations.last?.coordinate
            busy = false
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            busy = false
            message = "No location: \(error.localizedDescription)"
        }
    }
}
