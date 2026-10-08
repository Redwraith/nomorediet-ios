import Foundation

/// Data the app shares with its widget through the App Group container.
/// If the signing removed the App Group, `defaults` falls back to the app's own
/// defaults and the widget simply shows "Apri Nomorediet".
enum SharedStore {
    static let groupID = "group.app.piatto.ios"
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
