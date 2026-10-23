import Foundation
import HealthKit

/// Reads Apple Health (read-only): weight, body fat, steps, distance, active and resting energy, exercise
/// minutes, flights, heart rate, HRV, VO2 max, sleep and workouts. Health merges iPhone and Apple Watch and
/// removes duplicates itself (statistics queries count each minute once, from the best source), so steps
/// walked with both devices are not counted twice.
enum HealthBridge {
    private static let store = HKHealthStore()
    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    static func fetch(days: Int, completion: @escaping ([String: Any]) -> Void) {
        guard isAvailable else { return completion(["available": false]) }
        let mass = HKQuantityType(.bodyMass)
        let steps = HKQuantityType(.stepCount)
        let energy = HKQuantityType(.activeEnergyBurned)
        let sleep = HKCategoryType(.sleepAnalysis)
        let hrv = HKQuantityType(.heartRateVariabilitySDNN)
        let rhr = HKQuantityType(.restingHeartRate)
        let basal = HKQuantityType(.basalEnergyBurned)
        let distance = HKQuantityType(.distanceWalkingRunning)
        let exercise = HKQuantityType(.appleExerciseTime)
        let flights = HKQuantityType(.flightsClimbed)
        let heart = HKQuantityType(.heartRate)
        let vo2 = HKQuantityType(.vo2Max)
        let fat = HKQuantityType(.bodyFatPercentage)
        let workouts = HKObjectType.workoutType()
        let read: Set<HKObjectType> = [mass, steps, energy, sleep, hrv, rhr, basal, distance, exercise, flights, heart, vo2, fat, workouts]
        var share: Set<HKSampleType> = []
        #if DEBUG
        if UITestSupport.seedHealth { share = [steps, mass] }
        #endif
        store.requestAuthorization(toShare: share, read: read) { ok, error in
            guard ok, error == nil else {
                // the reason is shown in Profilo: e.g. a missing HealthKit entitlement after re-signing
                let reason = error?.localizedDescription ?? "accesso non concesso"
                return DispatchQueue.main.async { completion(["available": true, "authorized": false, "error": reason]) }
            }
            #if DEBUG
            // simulator UI tests: a week of steps and two weighings, written once, then read back like real data
            if UITestSupport.seedHealth && !UITestSupport.seeded {
                UITestSupport.seeded = true
                let samples = UITestSupport.healthSamples(steps: steps, mass: mass)
                return store.save(samples) { ok, error in
                    DebugLog.shared.add(ok ? "info" : "error", "health", "Dati di prova scritti in Salute: \(ok) \(error?.localizedDescription ?? "")")
                    fetch(days: days, completion: completion)
                }
            }
            #endif
            let cal = Calendar.current
            let start = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: Date()))!
            let predicate = HKQuery.predicateForSamples(withStart: start, end: Date())
            let box = ResultBox()
            let group = DispatchGroup()

            group.enter()
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            store.execute(HKSampleQuery(sampleType: mass, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
                let rows = (samples as? [HKQuantitySample] ?? []).map {
                    ["date": DayId.string($0.startDate), "kg": $0.quantity.doubleValue(for: .gramUnit(with: .kilo))] as [String: Any]
                }
                box.set { $0.weights = rows }
                group.leave()
            })

            // daily totals, iPhone + Apple Watch without duplicates
            let daily: [(String, HKQuantityType, HKUnit, Double)] = [
                ("steps", steps, .count(), 1), ("activeKcal", energy, .kilocalorie(), 1), ("basalKcal", basal, .kilocalorie(), 1),
                ("km", distance, .meterUnit(with: .kilo), 100), ("exerciseMin", exercise, .minute(), 1), ("flights", flights, .count(), 1),
            ]
            for (name, type, unit, precision) in daily {
                group.enter()
                let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                                                        options: .cumulativeSum, anchorDate: start,
                                                        intervalComponents: DateComponents(day: 1))
                query.initialResultsHandler = { _, collection, _ in
                    var out: [String: Double] = [:]
                    collection?.enumerateStatistics(from: start, to: Date()) { stats, _ in
                        if let value = stats.sumQuantity()?.doubleValue(for: unit) { out[DayId.string(stats.startDate)] = (value * precision).rounded() / precision }
                    }
                    box.set { $0.daily[name] = out }
                    group.leave()
                }
                store.execute(query)
            }

            let startOfDay = cal.startOfDay(for: Date())
            // average heart rate today
            group.enter()
            store.execute(HKStatisticsQuery(quantityType: heart, quantitySamplePredicate: HKQuery.predicateForSamples(withStart: startOfDay, end: Date()),
                                            options: .discreteAverage) { _, stats, _ in
                let bpm = stats?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                box.set { $0.latest["heartRateAvg"] = bpm.map { $0.rounded() } }
                group.leave()
            })
            // latest VO2 max and body fat
            let newest = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            for (name, type, unit, factor) in [("vo2max", vo2, HKUnit(from: "ml/kg*min"), 1.0), ("bodyFat", fat, HKUnit.percent(), 100.0)] {
                group.enter()
                store.execute(HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [newest]) { _, samples, _ in
                    let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                    box.set { $0.latest[name] = value.map { ($0 * factor * 10).rounded() / 10 } }
                    group.leave()
                })
            }
            // today's workouts (Apple Watch, Fitness, other apps)
            group.enter()
            store.execute(HKSampleQuery(sampleType: workouts, predicate: HKQuery.predicateForSamples(withStart: startOfDay, end: Date()),
                                        limit: 20, sortDescriptors: [newest]) { _, samples, _ in
                let rows = (samples as? [HKWorkout] ?? []).map { w -> [String: Any] in
                    let kcal = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
                    return ["name": HealthBridge.name(of: w.workoutActivityType), "minutes": (w.duration / 60).rounded(), "kcal": kcal.rounded()]
                }
                box.set { $0.workouts = rows }
                group.leave()
            })

            // Readiness: last night's sleep, today's HRV and resting heart rate against the previous 14 days.
            let startOfToday = cal.startOfDay(for: Date())
            group.enter()
            let night = HKQuery.predicateForSamples(withStart: startOfToday.addingTimeInterval(-6 * 3600), end: Date())
            store.execute(HKSampleQuery(sampleType: sleep, predicate: night, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                let asleep = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
                let spans = (samples as? [HKCategorySample] ?? []).filter { asleep.contains($0.value) }
                    .map { ($0.startDate, $0.endDate) }.sorted { $0.0 < $1.0 }
                // merge overlapping samples from watch and phone
                var total = 0.0
                var current: (Date, Date)?
                for span in spans {
                    if let c = current, span.0 <= c.1 { current = (c.0, max(c.1, span.1)) }
                    else { if let c = current { total += c.1.timeIntervalSince(c.0) }; current = span }
                }
                if let c = current { total += c.1.timeIntervalSince(c.0) }
                box.set { $0.sleepHours = spans.isEmpty ? nil : total / 3600 }
                group.leave()
            })
            let fifteen = HKQuery.predicateForSamples(withStart: cal.date(byAdding: .day, value: -15, to: startOfToday), end: Date())
            for (type, unit, isHRV) in [(hrv, HKUnit.secondUnit(with: .milli), true), (rhr, HKUnit.count().unitDivided(by: .minute()), false)] {
                group.enter()
                store.execute(HKSampleQuery(sampleType: type, predicate: fifteen, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                    let values = (samples as? [HKQuantitySample] ?? []).map { ($0.startDate, $0.quantity.doubleValue(for: unit)) }
                    let today = values.filter { $0.0 >= startOfToday.addingTimeInterval(-3 * 3600) }.map(\.1)
                    let before = values.filter { $0.0 < startOfToday.addingTimeInterval(-3 * 3600) }.map(\.1)
                    let mean: ([Double]) -> Double? = { $0.isEmpty ? nil : $0.reduce(0, +) / Double($0.count) }
                    box.set {
                        if isHRV { $0.hrvToday = mean(today); $0.hrvBase = mean(before) }
                        else { $0.rhrToday = mean(today); $0.rhrBase = mean(before) }
                    }
                    group.leave()
                })
            }

            group.notify(queue: .main) {
                var readiness: [String: Any] = [:]
                if let v = box.sleepHours { readiness["sleepHours"] = v }
                if let v = box.hrvToday { readiness["hrvToday"] = v }
                if let v = box.hrvBase { readiness["hrvBase"] = v }
                if let v = box.rhrToday { readiness["rhrToday"] = v }
                if let v = box.rhrBase { readiness["rhrBase"] = v }
                completion(["available": true, "authorized": true, "weights": box.weights, "steps": box.daily["steps"] ?? [:],
                            "activeKcal": box.daily["activeKcal"] ?? [:], "daily": box.daily, "latest": box.latest.compactMapValues { $0 },
                            "workouts": box.workouts, "readiness": readiness, "date": DayId.string(Date())])
            }
        }
    }
}

extension HealthBridge {
    static func name(of type: HKWorkoutActivityType) -> String {
        switch type {
        case .traditionalStrengthTraining, .functionalStrengthTraining: "Pesi"
        case .walking: "Camminata"
        case .running: "Corsa"
        case .cycling: "Bici"
        case .swimming: "Nuoto"
        case .highIntensityIntervalTraining: "HIIT"
        case .yoga: "Yoga"
        case .elliptical: "Ellittica"
        case .rowing: "Vogatore"
        case .stairClimbing, .stairs: "Scale"
        case .coreTraining: "Core"
        case .flexibility, .cooldown: "Stretching"
        case .hiking: "Escursione"
        case .soccer: "Calcio"
        case .tennis: "Tennis"
        default: "Allenamento"
        }
    }
}

/// Collects results from HealthKit's background handlers under a lock.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    var weights: [[String: Any]] = []
    var daily: [String: [String: Double]] = [:]
    var latest: [String: Double?] = [:]
    var workouts: [[String: Any]] = []
    var sleepHours: Double?
    var hrvToday: Double?
    var hrvBase: Double?
    var rhrToday: Double?
    var rhrBase: Double?
    func set(_ change: (ResultBox) -> Void) { lock.lock(); change(self); lock.unlock() }
}
