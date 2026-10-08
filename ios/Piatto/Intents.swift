import AppIntents
import Foundation

/// Action requested from Siri / Shortcuts / Back Tap, picked up by the page when the app opens.
enum PendingAction {
    private static let key = "pending.action"
    static func set(_ action: [String: Any]) {
        var value = action
        value["at"] = Date().timeIntervalSince1970
        UserDefaults.standard.set(value, forKey: key)
        DispatchQueue.main.async { NotificationCenter.default.post(name: .piattoPendingAction, object: nil) }
    }
    /// Returns and clears the pending action (ignored after 10 minutes).
    static func take() -> [String: Any]? {
        guard let value = UserDefaults.standard.dictionary(forKey: key) else { return nil }
        UserDefaults.standard.removeObject(forKey: key)
        let at = value["at"] as? Double ?? 0
        return Date().timeIntervalSince1970 - at < 600 ? value : nil
    }
}

extension Notification.Name {
    static let piattoPendingAction = Notification.Name("piattoPendingAction")
    static let piattoShowDebug = Notification.Name("piattoShowDebug")
}

struct PhotoMealIntent: AppIntent {
    static var title: LocalizedStringResource = "Fotografa il pasto"
    static var description = IntentDescription("Apre Nomorediet con la fotocamera pronta per il pasto.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PendingAction.set(["action": "photo"])
        return .result()
    }
}

struct LogWeightIntent: AppIntent {
    static var title: LocalizedStringResource = "Registra il peso"
    static var description = IntentDescription("Salva il peso di oggi in Nomorediet.")
    static var openAppWhenRun = true

    @Parameter(title: "Peso in kg")
    var kg: Double

    func perform() async throws -> some IntentResult & ProvidesDialog {
        PendingAction.set(["action": "weight", "kg": kg])
        let text = String(format: "%.1f", kg).replacingOccurrences(of: ".", with: ",")
        return .result(dialog: IntentDialog(stringLiteral: "Registro \(text) kg su Nomorediet."))
    }
}

struct ScalePhotoIntent: AppIntent {
    static var title: LocalizedStringResource = "Fotografa la bilancia"
    static var description = IntentDescription("Apre la fotocamera e legge il peso dal display della bilancia.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PendingAction.set(["action": "scale"])
        return .result()
    }
}

struct StartWorkoutIntent: AppIntent {
    static var title: LocalizedStringResource = "Apri l'allenamento"
    static var description = IntentDescription("Apre Nomorediet sulla scheda di allenamento di oggi.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PendingAction.set(["action": "workout"])
        return .result()
    }
}

struct PiattoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PhotoMealIntent(),
                    phrases: ["Fotografa il pasto con \(.applicationName)", "\(.applicationName) foto"],
                    shortTitle: "Foto pasto", systemImageName: "camera")
        AppShortcut(intent: LogWeightIntent(),
                    phrases: ["Registra il peso su \(.applicationName)", "\(.applicationName) peso"],
                    shortTitle: "Registra peso", systemImageName: "scalemass")
        AppShortcut(intent: ScalePhotoIntent(),
                    phrases: ["Fotografa la bilancia con \(.applicationName)", "\(.applicationName) bilancia"],
                    shortTitle: "Foto bilancia", systemImageName: "camera.viewfinder")
        AppShortcut(intent: SendHealthIntent(),
                    phrases: ["Invia i dati Salute a \(.applicationName)"],
                    shortTitle: "Dati Salute", systemImageName: "heart.text.square")
        AppShortcut(intent: StartWorkoutIntent(),
                    phrases: ["Inizia allenamento con \(.applicationName)", "\(.applicationName) allenamento"],
                    shortTitle: "Allenamento", systemImageName: "dumbbell")
    }
}
