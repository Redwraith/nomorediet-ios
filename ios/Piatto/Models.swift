import Foundation
import SwiftData

/// Nutrients for a given amount of food. Food values are stored per 100 g and scaled.
struct Nutrients: Codable, Hashable {
    var kcal = 0.0
    var protein = 0.0
    var carbs = 0.0
    var fat = 0.0
    var fiber = 0.0
    var iron = 0.0       // mg
    var calcium = 0.0    // mg
    var b12 = 0.0        // µg
    var zinc = 0.0       // mg

    static let zero = Nutrients()

    func scaled(_ factor: Double) -> Nutrients {
        Nutrients(kcal: kcal * factor, protein: protein * factor, carbs: carbs * factor, fat: fat * factor,
                  fiber: fiber * factor, iron: iron * factor, calcium: calcium * factor, b12: b12 * factor, zinc: zinc * factor)
    }

    static func + (a: Nutrients, b: Nutrients) -> Nutrients {
        Nutrients(kcal: a.kcal + b.kcal, protein: a.protein + b.protein, carbs: a.carbs + b.carbs, fat: a.fat + b.fat,
                  fiber: a.fiber + b.fiber, iron: a.iron + b.iron, calcium: a.calcium + b.calcium, b12: a.b12 + b.b12, zinc: a.zinc + b.zinc)
    }
}

enum MealSlot: String, Codable, CaseIterable, Identifiable {
    case colazione, pranzo, spuntino, cena
    var id: String { rawValue }
    var title: String {
        switch self {
        case .colazione: "Colazione"
        case .pranzo: "Pranzo"
        case .spuntino: "Spuntini"
        case .cena: "Cena"
        }
    }
    var icon: String {
        switch self {
        case .colazione: "cup.and.saucer.fill"
        case .pranzo: "fork.knife"
        case .spuntino: "carrot.fill"
        case .cena: "moon.stars.fill"
        }
    }
    /// The slot that fits the time of day, used when tapping "+": 4:00–10:29 breakfast, 10:30–11:29 snack,
    /// 11:30–14:59 lunch, 15:00–18:29 snack, 18:30–22:59 dinner, night snack otherwise.
    static var now: MealSlot { at(.now) }

    static func at(_ date: Date) -> MealSlot {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        switch (c.hour ?? 12) * 60 + (c.minute ?? 0) {
        case 240..<630: return .colazione
        case 630..<690: return .spuntino
        case 690..<900: return .pranzo
        case 900..<1110: return .spuntino
        case 1110..<1380: return .cena
        default: return .spuntino
        }
    }
}

/// One food eaten on a day.
@Model
final class FoodEntry {
    var day: String = ""
    var slotRaw: String = MealSlot.pranzo.rawValue
    var name: String = ""
    var grams: Double = 100
    /// Values for 100 g, so the amount can be edited later.
    var per100: Nutrients = Nutrients.zero
    var createdAt: Date = Date.now
    @Attribute(.externalStorage) var photo: Data?

    init(day: String, slot: MealSlot, name: String, grams: Double, per100: Nutrients, photo: Data? = nil) {
        self.day = day
        self.slotRaw = slot.rawValue
        self.name = name
        self.grams = grams
        self.per100 = per100
        self.photo = photo
        self.createdAt = .now
    }

    var slot: MealSlot {
        get { MealSlot(rawValue: slotRaw) ?? .pranzo }
        set { slotRaw = newValue.rawValue }
    }
    var nutrients: Nutrients { per100.scaled(grams / 100) }
}

@Model
final class WeightEntry {
    var day: String = ""
    var kg: Double = 0
    var source: String = "manuale"
    var createdAt: Date = Date.now

    init(day: String, kg: Double, source: String) {
        self.day = day
        self.kg = kg
        self.source = source
        self.createdAt = .now
    }
}

/// A meal saved for "Ripeti": the same foods again with one tap.
@Model
final class SavedMeal {
    var key: String = UUID().uuidString
    var name: String = ""
    var itemsData: Data = Data()
    var uses: Int = 0
    var lastUsed: Date = Date.now

    struct Item: Codable, Hashable {
        var name: String
        var grams: Double
        var per100: Nutrients
    }

    init(name: String, items: [Item]) {
        self.key = UUID().uuidString
        self.name = name
        self.itemsData = (try? JSONEncoder().encode(items)) ?? Data()
        self.uses = 0
        self.lastUsed = .now
    }

    var items: [Item] {
        get { (try? JSONDecoder().decode([Item].self, from: itemsData)) ?? [] }
        set { itemsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    var kcal: Double { items.reduce(0) { $0 + $1.per100.kcal * $1.grams / 100 } }
}

/// Foods the user added from a label, a barcode or by hand; they show up in search.
@Model
final class CustomFood {
    var name: String = ""
    var barcode: String?
    var per100: Nutrients = Nutrients.zero
    var portion: Double = 100
    var createdAt: Date = Date.now

    init(name: String, barcode: String? = nil, per100: Nutrients, portion: Double) {
        self.name = name
        self.barcode = barcode
        self.per100 = per100
        self.portion = portion
        self.createdAt = .now
    }
}

/// One set in the workout log.
@Model
final class SetLog {
    var day: String = ""
    var exercise: String = ""
    var index: Int = 1
    var reps: Int = 0
    var kg: Double = 0
    var rir: Int = 2
    var partials: Int = 0
    var createdAt: Date = Date.now

    init(day: String, exercise: String, index: Int, reps: Int, kg: Double, rir: Int, partials: Int = 0) {
        self.day = day
        self.exercise = exercise
        self.index = index
        self.reps = reps
        self.kg = kg
        self.rir = rir
        self.partials = partials
        self.createdAt = .now
    }
}

enum DayKind: String, Codable {
    case training, rest

    /// The saved kind of a day, or the one planned from the training weekdays in Profile.
    static func of(_ day: String, saved: DayKind?, profile: Profile = ProfileStore.shared.profile) -> DayKind {
        if let saved { return saved }
        let weekday = Calendar.current.component(.weekday, from: DayId.date(day))
        return profile.trainingWeekdaySet.contains(weekday) ? .training : .rest
    }
}

/// Per-day flags that are not food: training or rest day.
@Model
final class DayInfo {
    var day: String = ""
    var kindRaw: String = DayKind.rest.rawValue

    init(day: String, kind: DayKind) {
        self.day = day
        self.kindRaw = kind.rawValue
    }

    var kind: DayKind {
        get { DayKind(rawValue: kindRaw) ?? .rest }
        set { kindRaw = newValue.rawValue }
    }
}

extension DayId {
    static var today: String { string(.now) }
    static func date(_ id: String) -> Date {
        let parts = id.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return .now }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) ?? .now
    }
    static func shift(_ id: String, by days: Int) -> String {
        string(Calendar.current.date(byAdding: .day, value: days, to: date(id)) ?? .now)
    }
    static func label(_ id: String) -> String {
        if id == today { return "Oggi" }
        if id == shift(today, by: -1) { return "Ieri" }
        return date(id).formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "it_IT"))).capitalized
    }
}

extension Double {
    /// "12,5" style numbers for the Italian UI.
    func it(_ digits: Int = 0) -> String {
        formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "it_IT")))
    }
}

extension String {
    /// Reads "85,4" or "85.4".
    var italianDouble: Double? {
        Double(trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }
}
