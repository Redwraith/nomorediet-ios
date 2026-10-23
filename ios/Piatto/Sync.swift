import Foundation
import SwiftData
import UIKit
import WidgetKit

/// Side effects after data changes: widget, reminders, adaptive calories, Health.
enum Sync {
    /// Widget summary, reminders for meals already logged, hero points.
    static func afterFoodChange(context: ModelContext, day: String) {
        let profile = ProfileStore.shared.profile
        let entries = (try? context.fetch(FetchDescriptor<FoodEntry>(predicate: #Predicate { $0.day == day }))) ?? []
        let kind = DayKind.of(day, saved: (try? context.fetch(FetchDescriptor<DayInfo>(predicate: #Predicate { $0.day == day })))?.first?.kind, profile: profile)
        let goals = Nutrition.goals(profile, kind: kind)
        let totals = entries.reduce(Nutrients.zero) { $0 + $1.nutrients }

        let logged = Set(entries.map(\.slot)).compactMap { slot -> String? in
            switch slot {
            case .colazione, .pranzo, .cena: slot.rawValue
            case .spuntino: nil
            }
        }
        Reminders.markLogged(date: day, slots: logged)

        guard day == DayId.today else { return }
        var favorites: [SharedStore.Favorite] = []
        var saved = FetchDescriptor<SavedMeal>(sortBy: [SortDescriptor(\.uses, order: .reverse)])
        saved.fetchLimit = 4
        for meal in (try? context.fetch(saved)) ?? [] {
            favorites.append(SharedStore.Favorite(key: meal.key, dish: meal.name, kcal: Int(meal.kcal.rounded())))
        }
        SharedStore.save(SharedStore.Summary(
            kcalLeft: Int(max(goals.kcal - totals.kcal, 0).rounded()), kcalGoal: Int(goals.kcal),
            proteinLeft: Int(max(goals.protein - totals.protein, 0).rounded()), proteinGoal: Int(goals.protein),
            level: Hero.level, favorites: favorites, updated: .now))
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func saveMeal(_ items: [FoodEntry], slot: MealSlot, context: ModelContext) {
        let name = items.count == 1 ? items[0].name : "\(slot.title): " + items.prefix(3).map(\.name).joined(separator: ", ")
        context.insert(SavedMeal(name: name, items: items.map { SavedMeal.Item(name: $0.name, grams: $0.grams, per100: $0.per100) }))
        UINotificationFeedbackGeneratorShim.success()
    }

    static func repeatMeal(_ meal: SavedMeal, slot: MealSlot, day: String, context: ModelContext) {
        for item in meal.items {
            context.insert(FoodEntry(day: day, slot: slot, name: item.name, grams: item.grams, per100: item.per100))
        }
        meal.uses += 1
        meal.lastUsed = .now
        UINotificationFeedbackGeneratorShim.success()
        afterFoodChange(context: context, day: day)
        Hero.award(.food)
    }

    static func repeatMeal(key: String, context: ModelContext) {
        let meals = (try? context.fetch(FetchDescriptor<SavedMeal>(predicate: #Predicate { $0.key == key }))) ?? []
        if let meal = meals.first { repeatMeal(meal, slot: .now, day: DayId.today, context: context) }
    }

    static func saveWeight(_ kg: Double, day: String = DayId.today, source: String, context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<WeightEntry>(predicate: #Predicate { $0.day == day }))) ?? []
        if let entry = existing.first {
            entry.kg = kg
            entry.source = source
        } else {
            context.insert(WeightEntry(day: day, kg: kg, source: source))
        }
        if day == DayId.today { ProfileStore.shared.profile.weightKg = kg }
        updateAdaptive(context: context)
        Hero.award(.weight)
        UINotificationFeedbackGeneratorShim.success()
    }

    /// Recomputes adaptive maintenance from the last 28 days.
    static func updateAdaptive(context: ModelContext) {
        let from = DayId.shift(DayId.today, by: -28)
        let entries = (try? context.fetch(FetchDescriptor<FoodEntry>(predicate: #Predicate { $0.day >= from }))) ?? []
        var byDay: [String: Double] = [:]
        for e in entries where e.day < DayId.today { byDay[e.day, default: 0] += e.nutrients.kcal }
        let weights = ((try? context.fetch(FetchDescriptor<WeightEntry>(predicate: #Predicate { $0.day >= from }))) ?? [])
            .map { (DayId.date($0.day), $0.kg) }.sorted { $0.0 < $1.0 }
        var profile = ProfileStore.shared.profile
        profile.adaptiveTDEE = nil
        let formula = Nutrition.maintenance(profile)
        ProfileStore.shared.profile.adaptiveTDEE = Nutrition.adaptiveTDEE(intakes: Array(byDay.values), weights: weights, formula: formula)
    }

    /// Imports weights, steps and energy from Apple Health: read directly when the app has the HealthKit
    /// entitlement, otherwise as sent by the Shortcuts automation (`SendHealthIntent`).
    static func importHealth(context: ModelContext) {
        guard ProfileStore.shared.profile.useHealth else { return }
        let viaShortcuts = ShortcutHealth.hasData
        if viaShortcuts {
            applyHealth(ShortcutHealth.result(), context: context)
            HealthCache.shared.status = ShortcutHealth.statusText
        }
        guard HealthBridge.isAvailable else {
            if !viaShortcuts { HealthCache.shared.status = "Apple Salute non è disponibile su questo dispositivo." }
            return
        }
        HealthBridge.fetch(days: 60) { result in
            if let error = result["error"] as? String {
                DebugLog.shared.add("error", "health", "Apple Salute: \(error)")
                if !viaShortcuts { HealthCache.shared.status = "Non collegata: \(error)" }
                return
            }
            guard result["weights"] is [[String: Any]] else { return }
            let steps = (result["daily"] as? [String: [String: Double]])?["steps"] ?? [:]
            DebugLog.shared.add("info", "health", "Salute letta: passi su \(steps.count) giorni, oggi \(Int(steps[DayId.today] ?? 0)), pesate \((result["weights"] as? [[String: Any]])?.count ?? 0)")
            HealthCache.shared.status = "Collegata ✓"
            applyHealth(result, context: context)
        }
    }

    /// The "sincronizza" button: reads Health directly when the app can, otherwise runs the Shortcuts automation,
    /// which sends today's values back and returns to the app.
    static func syncHealth(context: ModelContext) {
        if ShortcutHealth.needsShortcut {
            ShortcutHealth.runShortcut()
        } else {
            importHealth(context: context)
        }
    }

    /// Uses a Health reading (direct or from Shortcuts): new weights into the diary (when a context is at hand),
    /// today's values for the coach, and energy and steps for the calorie target.
    static func applyHealth(_ result: [String: Any], context: ModelContext?) {
        let rows = result["weights"] as? [[String: Any]] ?? []
        var latest: [String: Double] = [:]
        for row in rows { if let day = row["date"] as? String, let kg = row["kg"] as? Double { latest[day] = kg } }
        if let context {
            let known = Set(((try? context.fetch(FetchDescriptor<WeightEntry>())) ?? []).map(\.day))
            for (day, kg) in latest where !known.contains(day) {
                context.insert(WeightEntry(day: day, kg: (kg * 10).rounded() / 10, source: "Salute"))
            }
        }
        if let today = latest[DayId.today] { ProfileStore.shared.profile.weightKg = (today * 10).rounded() / 10 }
        HealthCache.shared.update(result)
        // energy and steps from Health feed the calorie calculation (only real changes, to avoid churn)
        var profile = ProfileStore.shared.profile
        let tdee = HealthCache.shared.tdee, steps = HealthCache.shared.avgSteps
        if profile.healthTDEE.map({ abs($0 - (tdee ?? 0)) > 20 }) ?? (tdee != nil) || profile.avgSteps.map({ abs($0 - (steps ?? 0)) > 200 }) ?? (steps != nil) {
            profile.healthTDEE = tdee
            profile.avgSteps = steps
            ProfileStore.shared.profile = profile
        }
        if let context { updateAdaptive(context: context) }
    }
}

/// Last values read from Apple Health, for the coach.
final class HealthCache: ObservableObject {
    static let shared = HealthCache()
    /// What happened the last time Health was read (shown in Profilo).
    @Published var status: String?
    @Published var steps: Double?
    /// Steps per day (day id → steps), for the chart in Progressi.
    @Published var dailySteps: [String: Double] = [:]
    @Published var activeKcal: Double?
    @Published var sleepHours: Double?
    @Published var hrvToday: Double?
    @Published var hrvBase: Double?
    @Published var rhrToday: Double?
    @Published var rhrBase: Double?
    @Published var basalKcal: Double?
    @Published var km: Double?
    @Published var exerciseMin: Double?
    @Published var flights: Double?
    @Published var heartRateAvg: Double?
    @Published var vo2max: Double?
    @Published var bodyFat: Double?
    @Published var workouts: [(name: String, minutes: Double, kcal: Double)] = []
    /// Averages of the last 14 complete days.
    @Published var avgSteps: Double?
    @Published var avgActiveKcal: Double?
    /// Energy burned per day from Health (resting + active), when at least 7 complete days have both.
    @Published var tdee: Double?
    @Published var updated: Date?

    func update(_ result: [String: Any]) {
        let today = DayId.today
        let daily = result["daily"] as? [String: [String: Double]] ?? [:]
        steps = daily["steps"]?[today]
        dailySteps = daily["steps"] ?? [:]
        activeKcal = daily["activeKcal"]?[today]
        basalKcal = daily["basalKcal"]?[today]
        km = daily["km"]?[today]
        exerciseMin = daily["exerciseMin"]?[today]
        flights = daily["flights"]?[today]
        let latest = result["latest"] as? [String: Double] ?? [:]
        heartRateAvg = latest["heartRateAvg"]
        vo2max = latest["vo2max"]
        bodyFat = latest["bodyFat"]
        workouts = (result["workouts"] as? [[String: Any]] ?? []).map {
            ($0["name"] as? String ?? "Allenamento", $0["minutes"] as? Double ?? 0, $0["kcal"] as? Double ?? 0)
        }
        let summary = Self.summary(daily: daily, today: today)
        avgSteps = summary.steps
        avgActiveKcal = summary.active
        tdee = summary.tdee
        updated = Date()
        let r = result["readiness"] as? [String: Double] ?? [:]
        sleepHours = r["sleepHours"]
        hrvToday = r["hrvToday"]
        hrvBase = r["hrvBase"]
        rhrToday = r["rhrToday"]
        rhrBase = r["rhrBase"]
    }

    /// 14-day averages from Health, skipping today (incomplete) and days without data.
    static func summary(daily: [String: [String: Double]], today: String) -> (steps: Double?, active: Double?, tdee: Double?) {
        let days = (1...14).map { DayId.shift(today, by: -$0) }
        func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : (v.reduce(0, +) / Double(v.count)).rounded() }
        let steps = days.compactMap { daily["steps"]?[$0] }.filter { $0 > 300 }
        let active = days.compactMap { daily["activeKcal"]?[$0] }
        // resting + active: Apple Watch measures both; with only the iPhone, resting energy is usually missing
        let burned = days.compactMap { d -> Double? in
            guard let b = daily["basalKcal"]?[d], b > 800, let a = daily["activeKcal"]?[d] else { return nil }
            return b + a
        }
        return (mean(steps), mean(active), burned.count >= 7 ? mean(burned) : nil)
    }

    /// 0…100 readiness from sleep, HRV and resting heart rate against the user's baseline.
    var readiness: Int? {
        var score = 70.0, parts = 0
        if let s = sleepHours { score += (s - 7) * 8; parts += 1 }
        if let h = hrvToday, let b = hrvBase, b > 0 { score += (h / b - 1) * 60; parts += 1 }
        if let r = rhrToday, let b = rhrBase, b > 0 { score -= (r / b - 1) * 120; parts += 1 }
        return parts == 0 ? nil : Int(min(max(score, 5), 100).rounded())
    }
}

/// Points and levels for logging consistently.
enum Hero {
    enum Action { case food, weight, workout }
    private static let key = "hero.xp"
    private static let dayKey = "hero.days"

    static var xp: Int { UserDefaults.standard.integer(forKey: key) }
    static var level: Int { 1 + Int(sqrt(Double(xp) / 40)) }
    static var nextLevelXP: Int { 40 * level * level }
    static var title: String {
        switch level {
        case ..<3: "Recluta"
        case ..<5: "Allievo"
        case ..<8: "Guerriero"
        case ..<12: "Capitano"
        case ..<16: "Comandante"
        default: "Leggenda"
        }
    }

    /// Food and weight count once per day each; a workout always counts.
    static func award(_ action: Action) {
        let d = UserDefaults.standard
        var days = d.stringArray(forKey: dayKey) ?? []
        let tag = "\(DayId.today)-\(action)"
        if action != .workout {
            guard !days.contains(tag) else { return }
            days.append(tag)
            d.set(Array(days.suffix(200)), forKey: dayKey)
        }
        let points = switch action { case .food: 10; case .weight: 5; case .workout: 25 }
        d.set(xp + points, forKey: key)
    }
}

enum UINotificationFeedbackGeneratorShim {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}
