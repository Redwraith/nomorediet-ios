import Foundation

/// Data the app shares with its widget through the App Group container.
/// If the signing removed the App Group, `defaults` falls back to the app's own
/// defaults and the widget simply shows "Apri Nomorediet".
enum SharedStore {
    static let baseGroupID = "group.app.piatto.ios"
    /// SideStore and Impactor re-sign the app with the user's team and rename the App Group to
    /// "group.app.piatto.ios.<TEAM>" (the same suffix they add to the bundle id): use whichever one the app owns.
    static let groupID: String = {
        let id = Bundle.main.bundleIdentifier ?? ""
        let extra = id.replacingOccurrences(of: "app.piatto.ios", with: "").split(separator: ".").map(String.init)
        let teams = extra.filter { $0.count == 10 && $0.allSatisfy { $0.isUppercase || $0.isNumber } }
        let candidates = teams.map { baseGroupID + "." + $0 } + [baseGroupID]
        return candidates.first { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil } ?? baseGroupID
    }()
    static var defaults: UserDefaults { UserDefaults(suiteName: groupID) ?? .standard }

    struct Favorite: Codable, Hashable {
        var key: String
        var dish: String
        var kcal: Int
    }

    struct Summary: Codable {
        var kcalLeft: Int
        var kcalGoal: Int
        var proteinLeft: Int
        var proteinGoal: Int
        var level: Int
        var favorites: [Favorite]
        var updated: Date
    }

    static func save(_ summary: Summary) {
        if let data = try? JSONEncoder().encode(summary) { defaults.set(data, forKey: "summary") }
    }

    static func load() -> Summary? {
        guard let data = defaults.data(forKey: "summary") else { return nil }
        return try? JSONDecoder().decode(Summary.self, from: data)
    }
}
