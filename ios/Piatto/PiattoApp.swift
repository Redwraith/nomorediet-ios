import SwiftData
import SwiftUI
import UserNotifications

@main
struct PiattoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var app = AppState()
    @StateObject private var store = ProfileStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(store)
                .tint(Theme.accent)
                .onOpenURL { DeepLink.handle($0) }
        }
        .modelContainer(for: [FoodEntry.self, WeightEntry.self, SavedMeal.self, CustomFood.self, SetLog.self, DayInfo.self])
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Reminders.reschedule(); Supplements.reschedule() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: ProfileStore
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var updates = UpdateChecker.shared
    @State private var importingHealth = false
    @State private var healthMessage: String?

    var body: some View {
        Group {
            if store.profile.onboarded {
                TabView(selection: $app.tab) {
                    TodayView().tabItem { Label("Oggi", systemImage: "fork.knife.circle.fill").accessibilityIdentifier("tab-oggi") }.tag(AppState.Tab.oggi)
                    ProgressTab().tabItem { Label("Progressi", systemImage: "chart.xyaxis.line").accessibilityIdentifier("tab-progressi") }.tag(AppState.Tab.progressi)
                    WorkoutTab().tabItem { Label("Allenamento", systemImage: "dumbbell.fill").accessibilityIdentifier("tab-allenamento") }.tag(AppState.Tab.allenamento)
                    CoachTab().tabItem { Label("Coach", systemImage: "sparkles").accessibilityIdentifier("tab-coach") }.tag(AppState.Tab.coach)
                    ProfileTab().tabItem { Label("Profilo", systemImage: "person.crop.circle").accessibilityIdentifier("tab-profilo") }.tag(AppState.Tab.profilo)
                }
            } else {
                OnboardingView()
            }
        }
        .safeAreaInset(edge: .top) {
            if updates.showBanner, let release = updates.available { UpdateBanner(release: release) }
        }
        .sheet(item: $app.sheet) { sheet in
            switch sheet {
            case .addFood(let slot, let mode): AddFoodView(slot: slot, mode: mode)
            case .weight(let mode): WeightSheet(mode: mode).presentationDetents([.medium, .large])
            case .debug: DebugView(close: { app.sheet = nil })
            }
        }
        .overlay {
            if importingHealth {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Importo i dati di Salute…").font(.headline)
                    Text("Può volerci qualche minuto se lo storico è lungo.").font(.footnote).foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .alert("Apple Salute", isPresented: Binding(get: { healthMessage != nil }, set: { if !$0 { healthMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(healthMessage ?? "") }
        .onAppear(perform: handlePending)
        .onReceive(NotificationCenter.default.publisher(for: .piattoPendingAction)) { _ in handlePending() }
        .onReceive(NotificationCenter.default.publisher(for: .piattoShowDebug)) { _ in app.sheet = .debug }
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in app.sheet = .debug }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            if app.day != DayId.today && app.sheet == nil { app.day = DayId.today }
            handlePending()
            Sync.importHealth(context: context)
            Sync.afterFoodChange(context: context, day: DayId.today)
            FoodUpdater.updateIfNeeded()
            Task { await updates.checkIfNeeded() }
        }
    }

    /// Siri, Shortcuts, Back Tap and widget actions.
    private func handlePending() {
        guard store.profile.onboarded, let action = PendingAction.take(), let kind = action["action"] as? String else { return }
        DebugLog.shared.add("info", "app", "Azione: \(kind)")
        app.day = DayId.today
        switch kind {
        case "photo":
            app.tab = .oggi
            app.sheet = .addFood(.now, .photo)
        case "weight":
            if let kg = action["kg"] as? Double, kg >= 30, kg <= 300 {
                Sync.saveWeight((kg * 10).rounded() / 10, source: "Siri", context: context)
                app.tab = .progressi
            } else {
                app.sheet = .weight(.type)
            }
        case "scale":
            app.sheet = .weight(.scale)
        case "workout":
            app.tab = .allenamento
            app.openWorkout = true
        case "healthExport":
            guard let path = action["path"] as? String else { return }
            app.tab = .profilo
            importingHealth = true
            let since = DayId.shift(DayId.today, by: -ShortcutHealth.keptDays)
            Task {
                let url = URL(fileURLWithPath: path)
                let summary = await Task.detached(priority: .userInitiated) { HealthExportReader.read(file: url, since: since) }.value
                try? FileManager.default.removeItem(at: url)
                importingHealth = false
                if let summary, summary.records > 0 {
                    healthMessage = ShortcutHealth.importExport(summary, context: context)
                } else {
                    healthMessage = "Non trovo dati di Salute in questo file: usa export.zip o export.xml di \"Esporta tutti i dati sanitari\". Dettagli nel pannello di debug (scuoti l'iPhone)."
                }
                DebugLog.shared.add("info", "health", healthMessage ?? "")
            }
        case "repeat":
            if let key = action["key"] as? String { Sync.repeatMeal(key: key, context: context) }
            app.tab = .oggi
        default:
            app.tab = .oggi
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        DebugLog.shared.startCrashReports()
        FoodUpdater.register()
        FoodUpdater.schedule()
        Reminders.reschedule()
        Supplements.registerCategory()
        Supplements.reschedule()
        GymMonitor.shared.resume()
        return true
    }

    // "Presa ✓" on a supplement reminder, or a tap on the gym notification.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if !Supplements.handle(response), let action = response.notification.request.content.userInfo["action"] as? String {
            PendingAction.set(["action": action])
        }
        completionHandler()
    }

    // Show reminders as banners even while the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// "New version" banner: SideStore installs the update with one tap.
struct UpdateBanner: View {
    let release: UpdateChecker.Release
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.app.fill").font(.title2).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nomorediet \(release.version) disponibile").font(.subheadline.bold())
                Text("Con SideStore: un tocco · con Sideloadly: scarica l'.ipa").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Aggiorna") { updates.openSideStore() }.buttonStyle(.borderedProminent)
            Button { updates.dismissedBuild = release.build } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Nascondi")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }
}

/// nomorediet:// links from the widget: photo, scale, workout, repeat?key=…, debug
enum DeepLink {
    static func handle(_ url: URL) {
        // export.zip / export.xml opened from Health's share sheet or from Files
        if url.isFileURL {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("salute-" + url.lastPathComponent)
            try? FileManager.default.removeItem(at: copy)
            do { try FileManager.default.copyItem(at: url, to: copy) } catch {
                DebugLog.shared.add("error", "health", "File ricevuto ma non copiabile: \(url.lastPathComponent) (\(error.localizedDescription))")
                return
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? Int) ?? 0
            DebugLog.shared.add("info", "health", "File ricevuto: \(url.lastPathComponent), \(size / 1_000_000) MB")
            PendingAction.set(["action": "healthExport", "path": copy.path])
            return
        }
        guard url.scheme == "nomorediet" else { return }
        let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "key" }?.value
        switch url.host {
        case "photo": PendingAction.set(["action": "photo"])
        case "scale": PendingAction.set(["action": "scale"])
        case "workout": PendingAction.set(["action": "workout"])
        case "repeat": if let key { PendingAction.set(["action": "repeat", "key": key]) }
        case "debug": NotificationCenter.default.post(name: .piattoShowDebug, object: nil)
        case "health": ShortcutHealth.handle(url)
        default: PendingAction.set(["action": "diario"])
        }
    }
}

extension Notification.Name {
    static let deviceDidShake = Notification.Name("deviceDidShake")
}

/// Shaking the iPhone opens the debug panel.
extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { NotificationCenter.default.post(name: .deviceDidShake, object: nil) }
        super.motionEnded(motion, with: event)
    }
}
