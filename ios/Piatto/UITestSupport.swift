#if DEBUG
import Foundation
import HealthKit

/// Hooks for the simulator UI tests (Debug builds only, never in the .ipa):
/// `-uiTesting` skips onboarding with a test profile, `-seedHealth` writes sample steps and weight into the
/// simulator's Health so the sync can be tested end to end.
enum UITestSupport {
    static let arguments = ProcessInfo.processInfo.arguments
    static var active: Bool { arguments.contains("-uiTesting") }
    static var seedHealth: Bool { arguments.contains("-seedHealth") }
    static var seeded = false

    static func apply() {
        guard active else { return }
        var profile = ProfileStore.shared.profile
        if !profile.onboarded {
            profile.name = "Test"
            profile.onboarded = true
        }
        profile.useHealth = true
        ProfileStore.shared.profile = profile
    }

    static func healthSamples(steps: HKQuantityType, mass: HKQuantityType) -> [HKSample] {
        let cal = Calendar.current
        var out: [HKSample] = []
        for day in 0..<7 {
            guard let start = cal.date(byAdding: .day, value: -day, to: cal.startOfDay(for: .now))?.addingTimeInterval(9 * 3600) else { continue }
            let count = Double(6000 + day * 750)
            out.append(HKQuantitySample(type: steps, quantity: HKQuantity(unit: .count(), doubleValue: count),
                                        start: start, end: start.addingTimeInterval(3600)))
        }
        for (day, kg) in [(0, 85.4), (3, 85.9)] {
            if let date = cal.date(byAdding: .day, value: -day, to: .now) {
                out.append(HKQuantitySample(type: mass, quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kg), start: date, end: date))
            }
        }
        return out
    }
}
#endif
