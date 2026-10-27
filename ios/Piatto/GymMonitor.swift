import CoreLocation
import MapKit
import SwiftUI
import UserNotifications

/// Arriving at the gym opens today's workout; leaving it after training reminds the creatine.
/// Uses iOS region monitoring (a 150 m circle around the gym): it works with the app closed, costs almost
/// no battery and the position never leaves the iPhone. iOS does not let an app open itself from the
/// background, so outside the app a notification appears: one tap opens the session.
final class GymMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = GymMonitor()

    struct Gym: Codable, Equatable {
        var name: String
        var address: String
        var latitude: Double
        var longitude: Double
        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    }

    @Published private(set) var gym: Gym?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var inside = false
    /// iOS can deliver the same region entry twice within a second or two.
    private var lastEnter: Date?
    private let manager = CLLocationManager()
    private static let key = "gym.v1"
    private static let regionId = "gym"
    static let radius: CLLocationDistance = 150

    override init() {
        super.init()
        manager.delegate = self
        authorization = manager.authorizationStatus
        if let data = UserDefaults.standard.data(forKey: Self.key) { gym = try? JSONDecoder().decode(Gym.self, from: data) }
    }

    /// Called at launch (also when iOS relaunches the app for a region event) so events reach the delegate.
    func resume() {
        guard let gym else { return }
        if !manager.monitoredRegions.contains(where: { $0.identifier == Self.regionId }) { startMonitoring(gym) }
    }

    func set(_ gym: Gym) {
        self.gym = gym
        if let data = try? JSONEncoder().encode(gym) { UserDefaults.standard.set(data, forKey: Self.key) }
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.requestAlwaysAuthorization()
        startMonitoring(gym)
        DebugLog.shared.add("info", "gym", "Palestra impostata: \(gym.name)")
    }

    func remove() {
        gym = nil
        UserDefaults.standard.removeObject(forKey: Self.key)
        manager.monitoredRegions.filter { $0.identifier == Self.regionId }.forEach { manager.stopMonitoring(for: $0) }
    }

    private func startMonitoring(_ gym: Gym) {
        manager.monitoredRegions.filter { $0.identifier == Self.regionId }.forEach { manager.stopMonitoring(for: $0) }
        let region = CLCircularRegion(center: gym.coordinate, radius: Self.radius, identifier: Self.regionId)
        region.notifyOnEntry = true
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
        manager.requestState(for: region)
    }

    // MARK: Delegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { self.authorization = manager.authorizationStatus }
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard region.identifier == Self.regionId else { return }
        DispatchQueue.main.async { self.inside = state == .inside }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == Self.regionId else { return }
        if let last = lastEnter, Date().timeIntervalSince(last) < 60 { return }
        lastEnter = Date()
        DebugLog.shared.add("info", "gym", "Arrivato in palestra")
        DispatchQueue.main.async {
            self.inside = true
            // only once per day: walking past the gym again does not reopen the session
            let key = "gym.opened.\(DayId.today)"
            guard !UserDefaults.standard.bool(forKey: key) else { return }
            UserDefaults.standard.set(true, forKey: key)
            if UIApplication.shared.applicationState == .active {
                PendingAction.set(["action": "workout"])
            } else {
                let content = UNMutableNotificationContent()
                content.title = "Sei da \(self.gym?.name ?? "palestra") 💪"
                content.body = "Tocca per aprire l'allenamento di oggi."
                content.sound = .default
                content.interruptionLevel = .timeSensitive
                content.userInfo = ["action": "workout"]
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "gym.enter", content: content, trigger: nil))
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == Self.regionId else { return }
        DebugLog.shared.add("info", "gym", "Uscito dalla palestra")
        DispatchQueue.main.async {
            self.inside = false
            if UserDefaults.standard.bool(forKey: "trained.\(DayId.today)") { Supplements.workoutFinished() }
        }
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        DebugLog.shared.add("error", "gym", "Monitoraggio palestra non riuscito: \(error.localizedDescription)")
    }

    // MARK: Finding the gym

    /// Current position, asking "while in use" permission if needed. Never waits more than `timeout`:
    /// indoors (inside a gym) the GPS can stay imprecise for minutes, so the best fix so far is used.
    func currentLocation(timeout: Duration = .seconds(8)) async -> CLLocation? {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        final class Best: @unchecked Sendable { var location: CLLocation? }
        let best = Best()
        let precise = await withTaskGroup(of: CLLocation?.self) { group -> CLLocation? in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if update.authorizationDenied { return nil }
                        guard let location = update.location else { continue }
                        if best.location.map({ location.horizontalAccuracy < $0.horizontalAccuracy }) ?? true { best.location = location }
                        if location.horizontalAccuracy < 100 { return location }
                    }
                } catch {}
                return nil
            }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let found = precise ?? best.location ?? manager.location
        DebugLog.shared.add("info", "gym", found.map { "Posizione ±\(Int($0.horizontalAccuracy)) m" } ?? "Posizione non disponibile")
        return found
    }

    /// Gyms matching the text ("Fit Active") around the current position, nearest first.
    func search(_ text: String, near location: CLLocation?) async -> [Gym] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.pointOfInterest, .address]
        if let location { request.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 30_000, longitudinalMeters: 30_000) }
        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: request).start()
        } catch {
            DebugLog.shared.add("error", "gym", "Ricerca palestra: \(error.localizedDescription)")
            return []
        }
        return response.mapItems.compactMap { item -> Gym? in
            let c = item.placemark.coordinate
            let address = [item.placemark.thoroughfare, item.placemark.subThoroughfare, item.placemark.locality].compactMap { $0 }.joined(separator: " ")
            return Gym(name: item.name ?? text, address: address, latitude: c.latitude, longitude: c.longitude)
        }
        .sorted { a, b in
            guard let location else { return false }
            return location.distance(from: CLLocation(latitude: a.latitude, longitude: a.longitude))
                < location.distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        }
    }
}

/// Profile → Palestra.
struct GymSettingsView: View {
    @ObservedObject private var monitor = GymMonitor.shared
    @State private var query = "Fit Active"
    @State private var results: [GymMonitor.Gym] = []
    @State private var location: CLLocation?
    @State private var searching = false
    @State private var status: String?

    var body: some View {
        Form {
            if let gym = monitor.gym {
                Section {
                    Map(initialPosition: .region(MKCoordinateRegion(center: gym.coordinate, latitudinalMeters: 600, longitudinalMeters: 600))) {
                        Marker(gym.name, systemImage: "dumbbell.fill", coordinate: gym.coordinate).tint(Theme.accent)
                        MapCircle(center: gym.coordinate, radius: GymMonitor.radius).foregroundStyle(Theme.accent.opacity(0.2))
                    }
                    .frame(height: 180)
                    .listRowInsets(EdgeInsets())
                    LabeledContent("Palestra", value: gym.name)
                    if !gym.address.isEmpty { LabeledContent("Indirizzo", value: gym.address) }
                    if monitor.inside { Label("Sei in palestra adesso", systemImage: "location.fill").foregroundStyle(Theme.accent) }
                    Button("Rimuovi palestra", role: .destructive) { monitor.remove() }
                } header: { Text("La tua palestra") }
            }
            if monitor.gym != nil && monitor.authorization != .authorizedAlways {
                Section {
                    Label("Per accorgermi che arrivi anche ad app chiusa, in Impostazioni → Nomorediet → Posizione scegli \"Sempre\".",
                          systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                    Button("Apri Impostazioni") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            }
            Section {
                HStack {
                    TextField("Nome della palestra", text: $query).submitLabel(.search).onSubmit { Task { await search() } }
                    Button { Task { await search() } } label: { searching ? AnyView(ProgressView()) : AnyView(Image(systemName: "magnifyingglass")) }
                        .disabled(query.isEmpty || searching)
                }
                ForEach(results, id: \.latitude) { gym in
                    Button {
                        monitor.set(gym)
                        results = []
                        status = "Fatto: quando arrivi da \(gym.name) ti apro l'allenamento."
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(gym.name).font(.headline)
                                Text([gym.address, distance(gym)].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Scegli").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    status = "Cerco la tua posizione…"
                    Task {
                        guard let here = await GymMonitor.shared.currentLocation() else { status = "Posizione non disponibile: consenti la posizione in Impostazioni."; return }
                        monitor.set(GymMonitor.Gym(name: query.isEmpty ? "Palestra" : query, address: "", latitude: here.coordinate.latitude, longitude: here.coordinate.longitude))
                        status = "Fatto: questa posizione è la tua palestra."
                    }
                } label: { Label("Sono in palestra adesso: usa questa posizione", systemImage: "location") }
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text(monitor.gym == nil ? "Scegli la palestra" : "Cambia palestra") } footer: {
                Text("Quando arrivi (entro 150 m) ti apro l'allenamento di oggi; quando esci dopo esserti allenato ti ricordo la creatina. La posizione resta sull'iPhone.")
            }
        }
        .navigationTitle("Palestra")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func search() async {
        searching = true
        defer { searching = false }
        status = nil
        if location == nil { location = await GymMonitor.shared.currentLocation() }
        results = await GymMonitor.shared.search(query, near: location)
        status = results.isEmpty ? "Nessun risultato vicino a te. Prova un altro nome o usa la posizione attuale quando sei lì." : nil
    }

    private func distance(_ gym: GymMonitor.Gym) -> String {
        guard let location else { return "" }
        let meters = location.distance(from: CLLocation(latitude: gym.latitude, longitude: gym.longitude))
        return meters < 1000 ? "\(Int(meters)) m" : "\((meters / 1000).it(1)) km"
    }
}
