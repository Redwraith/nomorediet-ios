import Foundation
import SwiftUI

/// The user's profile and preferences, saved in UserDefaults.
struct Profile: Codable, Equatable {
    enum Sex: String, Codable, CaseIterable { case uomo, donna }
    enum Goal: String, Codable, CaseIterable {
        case dimagrire, ricomposizione, mantenere, massa
        var title: String {
            switch self {
            case .dimagrire: "Dimagrire"
            case .ricomposizione: "Ricomposizione"
            case .mantenere: "Mantenere"
            case .massa: "Aumentare la massa"
            }
        }
        /// Daily calories relative to maintenance.
        var delta: Double {
            switch self {
            case .dimagrire: -0.20 // replaced by the plan's deficit (Nutrition.dailyTarget)
            case .ricomposizione: -0.10
            case .mantenere: 0
            case .massa: 0.10
            }
        }
    }
    enum Activity: String, Codable, CaseIterable {
        case sedentario, leggero, moderato, intenso
        var title: String {
            switch self {
            case .sedentario: "Sedentario (ufficio, pochi passi)"
            case .leggero: "Leggero (6–8 mila passi)"
            case .moderato: "Moderato (10 mila passi, lavoro in piedi)"
            case .intenso: "Intenso (lavoro fisico)"
            }
        }
        /// Multiplier on resting metabolism, before training (added separately on training days).
        var factor: Double {
            switch self {
            case .sedentario: 1.25
            case .leggero: 1.35
            case .moderato: 1.45
            case .intenso: 1.6
            }
        }
    }

    /// How calories and macros are split across the week.
    enum Diet: String, Codable, CaseIterable, Identifiable {
        case bilanciata, carbCycling, mediterranea, iperproteica, lowCarb, chetogenica
        var id: String { rawValue }
        var title: String {
            switch self {
            case .bilanciata: "Bilanciata"
            case .carbCycling: "Carb cycling"
            case .mediterranea: "Mediterranea"
            case .iperproteica: "Iperproteica"
            case .lowCarb: "Low carb"
            case .chetogenica: "Chetogenica"
            }
        }
        var summary: String {
            switch self {
            case .bilanciata: "Proteine alte, grassi moderati, carboidrati per il resto. Poco più cibo nei giorni di allenamento."
            case .carbCycling: "Giorni di allenamento ricchi di carboidrati e poveri di grassi; giorni di riposo con pochi carboidrati e più grassi. Stesse calorie settimanali."
            case .mediterranea: "Circa 50% carboidrati e 30% grassi (olio d'oliva, legumi, cereali integrali), proteine adeguate."
            case .iperproteica: "Proteine a 2,4 g/kg per proteggere i muscoli in definizione; carboidrati e grassi ridotti di conseguenza."
            case .lowCarb: "Circa 100 g di carboidrati al giorno (di più nei giorni di allenamento), grassi più alti."
            case .chetogenica: "Sotto i 30 g di carboidrati al giorno, grassi alti. Da seguire con attenzione: chiedi al medico se hai patologie."
            }
        }
    }

    var name = ""
    var sex = Sex.uomo
    var age = 30
    var heightCm = 173.0
    var weightKg = 86.0
    var targetKg = 78.0
    var goal = Goal.ricomposizione
    var activity = Activity.leggero
    var vegetarian = true
    var trainingDays = 4
    /// Calories burned by one workout, added on training days.
    var workoutKcal = 300.0
    /// Fixed goal set by hand instead of the calculated one.
    var manualKcal: Double? = nil
    var onboarded = false
    var simpleMode = false
    var useHealth = true
    var reminders = true
    var reminderTimes: [String: String] = ["colazione": "08:30", "pranzo": "13:15", "cena": "20:15", "checkin": "21:45"]
    /// Maintenance estimated from the logged food and weight trend (adaptive calories).
    var adaptiveTDEE: Double? = nil
    /// Optional so profiles saved by older versions still decode.
    var dietType: Diet? = nil
    var diet: Diet {
        get { dietType ?? .bilanciata }
        set { dietType = newValue }
    }
    /// Energy burned per day measured by Apple Health (resting + active, 14-day average).
    var healthTDEE: Double? = nil
    /// Average daily steps from Apple Health (iPhone + Apple Watch), last 14 days.
    var avgSteps: Double? = nil
    /// Weight-loss speed chosen in the plan, kg per week (nil = 0.5).
    var weeklyLossKg: Double? = nil
    var lossPerWeek: Double {
        get { weeklyLossKg ?? 0.5 }
        set { weeklyLossKg = newValue }
    }
    /// Training weekdays (1 = Sunday … 7 = Saturday, as in Calendar), for reminders and carb cycling.
    var trainingWeekdays: [Int]? = nil
    var trainingWeekdaySet: Set<Int> {
        get { Set(trainingWeekdays ?? [2, 3, 5, 6]) }
        set { trainingWeekdays = newValue.sorted() }
    }
}

final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()
    @Published var profile: Profile {
        didSet { save() }
    }
    private static let key = "profile.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(Profile.self, from: data) {
            profile = saved
        } else {
            profile = Profile()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profile) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// Daily targets.
struct Goals: Equatable {
    var kcal: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var fiber: Double
    var iron: Double
    var calcium: Double
    var b12: Double
    var zinc: Double
}

enum Nutrition {
    /// Mifflin-St Jeor resting metabolism.
    static func bmr(_ p: Profile) -> Double {
        let base = 10 * p.weightKg + 6.25 * p.heightCm - 5 * Double(p.age)
        return p.sex == .uomo ? base + 5 : base - 161
    }

    /// Where the maintenance estimate comes from, best first.
    enum Source { case adaptive, health, steps, formula }

    static func maintenanceSource(_ p: Profile) -> Source {
        if p.adaptiveTDEE != nil { return .adaptive }
        if p.healthTDEE != nil { return .health }
        return p.avgSteps != nil ? .steps : .formula
    }

    /// Lifestyle multiplier from the steps measured by Health, when known.
    static func stepFactor(_ steps: Double) -> Double {
        switch steps {
        case ..<4000: 1.2
        case ..<7000: 1.3
        case ..<10000: 1.4
        case ..<13000: 1.5
        default: 1.6
        }
    }

    /// Calories burned on an average day, training included: from the food diary and weight trend (adaptive),
    /// else from Apple Health (resting + active energy), else from steps or the chosen activity level.
    static func maintenance(_ p: Profile) -> Double {
        if let tdee = p.adaptiveTDEE { return tdee }
        if let tdee = p.healthTDEE { return tdee }
        let factor = p.avgSteps.map(stepFactor) ?? p.activity.factor
        return bmr(p) * factor + p.workoutKcal * Double(p.trainingDays) / 7
    }

    /// Lowest daily intake the app will suggest.
    static func floor(_ p: Profile) -> Double { max(bmr(p), p.sex == .uomo ? 1500 : 1200).rounded() }

    /// Average daily calories for the goal. Losing weight: maintenance minus the deficit for the chosen speed
    /// (7,700 kcal ≈ 1 kg of body fat), never below `floor`.
    static func dailyTarget(_ p: Profile) -> Double {
        if let manual = p.manualKcal { return manual }
        let m = maintenance(p)
        if p.goal == .dimagrire { return max(m - p.lossPerWeek * 7700 / 7, floor(p)) }
        return m * (1 + p.goal.delta)
    }

    struct Plan {
        var maintenance: Double
        var daily: Double
        var deficit: Double
        /// Expected loss per week at `daily`.
        var weekly: Double
        var kgToLose: Double
        var weeks: Int?
        var date: Date?
        /// The floor limited the deficit: slower than chosen.
        var limited: Bool
    }

    /// The weight-loss plan towards the target weight.
    static func plan(_ p: Profile, from start: Date = .now) -> Plan {
        let m = maintenance(p)
        let daily = dailyTarget(p)
        let deficit = max(0, m - daily)
        let weekly = deficit * 7 / 7700
        let toLose = max(0, p.weightKg - p.targetKg)
        let weeks = weekly > 0.05 && toLose > 0 ? Int((toLose / weekly).rounded(.up)) : nil
        let date = weeks.flatMap { Calendar.current.date(byAdding: .day, value: $0 * 7, to: start) }
        let wanted = m - p.lossPerWeek * 7700 / 7
        return Plan(maintenance: m.rounded(), daily: daily.rounded(), deficit: deficit.rounded(), weekly: weekly, kgToLose: toLose,
                    weeks: weeks, date: date, limited: p.manualKcal == nil && wanted < floor(p))
    }

    /// Targets for one day. Training days get more carbs, rest days fewer,
    /// so the weekly average matches the goal.
    static func goals(_ p: Profile, kind: DayKind) -> Goals {
        let avg = dailyTarget(p)
        let train = Double(p.trainingDays), rest = 7 - train
        // move calories from rest days to training days, keeping the weekly total
        let shift = avg * (p.diet == .carbCycling ? 0.20 : 0.12)
        let trainKcal = avg + shift * rest / 7
        let restKcal = avg - shift * train / 7
        let kcal = (kind == .training ? trainKcal : restKcal).rounded()
        let training = kind == .training

        // protein ~2 g/kg (reference weight capped for higher body fat), then fat and carbs by diet type
        let refKg = min(p.weightKg, p.heightCm - 100 + 10)
        var protein = (refKg * (p.goal == .massa ? 1.8 : 2.0)).rounded()
        var fat: Double, carbs: Double
        switch p.diet {
        case .bilanciata:
            fat = max(p.weightKg * 0.8, kcal * 0.22 / 9)
            carbs = max((kcal - protein * 4 - fat * 9) / 4, 50)
        case .carbCycling:
            // high carb / low fat when training, low carb / higher fat when resting
            fat = training ? max(p.weightKg * 0.5, kcal * 0.15 / 9) : max(p.weightKg * 1.1, kcal * 0.35 / 9)
            carbs = max((kcal - protein * 4 - fat * 9) / 4, training ? 120 : 60)
        case .mediterranea:
            protein = max((refKg * 1.6).rounded(), (kcal * 0.18 / 4).rounded())
            fat = kcal * 0.30 / 9
            carbs = max((kcal - protein * 4 - fat * 9) / 4, 50)
        case .iperproteica:
            protein = (refKg * 2.4).rounded()
            fat = max(p.weightKg * 0.7, kcal * 0.20 / 9)
            carbs = max((kcal - protein * 4 - fat * 9) / 4, 50)
        case .lowCarb:
            carbs = training ? 130 : 80
            fat = max((kcal - protein * 4 - carbs * 4) / 9, p.weightKg * 0.8)
        case .chetogenica:
            carbs = 25
            fat = max((kcal - protein * 4 - carbs * 4) / 9, p.weightKg * 1.0)
        }
        fat = fat.rounded()
        carbs = carbs.rounded()

        let male = p.sex == .uomo
        // vegetarian iron needs are ~1.8×, zinc ~1.5× (non-heme iron and phytates)
        let iron = (male ? 8.0 : 18.0) * (p.vegetarian ? 1.8 : 1)
        let zinc = (male ? 11.0 : 8.0) * (p.vegetarian ? 1.5 : 1)
        return Goals(kcal: kcal, protein: protein, carbs: carbs, fat: fat, fiber: male ? 38 : 25,
                     iron: iron.rounded(), calcium: p.age > 50 ? 1200 : 1000, b12: 2.4, zinc: zinc.rounded())
    }

    /// Adaptive maintenance: average intake minus the energy in the weight change.
    /// Needs at least 10 days with food logged and 2 weeks of weights.
    /// Maintenance from what was eaten and how the weight moved. Days logged only in part (under 60% of the
    /// formula estimate) are left out: a forgotten lunch is not a diet, and it would make maintenance look lower
    /// than it is. The result stays within −20% / +25% of the formula, so a gap in the diary cannot push it far.
    static func adaptiveTDEE(intakes: [Double], weights: [(Date, Double)], formula: Double? = nil) -> Double? {
        let minimum = formula.map { $0 * 0.6 } ?? 600
        let logged = intakes.filter { $0 >= minimum }
        guard logged.count >= 10, weights.count >= 4,
              let first = weights.first, let last = weights.last else { return nil }
        let days = last.0.timeIntervalSince(first.0) / 86400
        guard days >= 13 else { return nil }
        let slope = trend(weights).slope // kg per day
        let avgIntake = logged.reduce(0, +) / Double(logged.count)
        var tdee = avgIntake - slope * 7700
        if let formula { tdee = min(max(tdee, formula * 0.8), formula * 1.25) }
        return tdee.rounded()
    }

    /// Least-squares line through weights over time: slope in kg/day.
    static func trend(_ points: [(Date, Double)]) -> (slope: Double, intercept: Double, origin: Date) {
        guard let origin = points.first?.0, points.count >= 2 else { return (0, points.first?.1 ?? 0, points.first?.0 ?? .now) }
        let xs = points.map { $0.0.timeIntervalSince(origin) / 86400 }, ys = points.map(\.1)
        let n = Double(points.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let num = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let den = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        let slope = den == 0 ? 0 : num / den
        return (slope, my - slope * mx, origin)
    }
}
