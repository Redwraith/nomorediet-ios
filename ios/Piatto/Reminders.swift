import Foundation
import UserNotifications

/// Meal reminders scheduled one by one for the next 7 days, so a reminder for a meal
/// the user has already logged today can be removed. The page sends the times
/// ("reminders") and the meals logged today ("logged"); the app reschedules on launch.
enum Reminders {
    struct Slot { let id: String; let body: String; let time: String }
    private static let slots: [Slot] = [
        Slot(id: "colazione", body: "Registra la colazione: basta una foto.", time: "08:30"),
        Slot(id: "pranzo", body: "Com'era il pranzo? Fotografa il piatto.", time: "13:15"),
        Slot(id: "cena", body: "Registra la cena prima di dimenticartene.", time: "20:15"),
        Slot(id: "checkin", body: "Check-in serale: guarda come è andata oggi.", time: "21:45"),
    ]
    private static let defaults = UserDefaults.standard

    static func configure(times: [String: String], enabled: Bool) {
        defaults.set(times, forKey: "rem.times")
        defaults.set(enabled, forKey: "rem.enabled")
        reschedule()
    }

    static func markLogged(date: String, slots logged: [String]) {
        defaults.set(logged, forKey: "rem.logged." + date)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: logged.map { "piatto.\($0).\(date)" })
    }

    static func reschedule() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            center.getPendingNotificationRequests { pending in
                center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("piatto.") })
                guard defaults.object(forKey: "rem.enabled") as? Bool ?? true else { return }
                let times = defaults.dictionary(forKey: "rem.times") as? [String: String] ?? [:]
                let cal = Calendar.current
                let now = Date()
                for offset in 0..<7 {
                    guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now)) else { continue }
                    let id = DayId.string(day)
                    let logged = Set(defaults.stringArray(forKey: "rem.logged." + id) ?? [])
                    for slot in slots where !logged.contains(slot.id) {
                        let parts = (times[slot.id] ?? slot.time).split(separator: ":").compactMap { Int($0) }
                        guard parts.count == 2 else { continue }
                        var when = cal.dateComponents([.year, .month, .day], from: day)
                        when.hour = parts[0]
                        when.minute = parts[1]
                        guard let fire = cal.date(from: when), fire > now else { continue }
                        let content = UNMutableNotificationContent()
                        content.title = "Nomorediet"
                        content.body = slot.body
                        content.sound = .default
                        let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
                        center.add(UNNotificationRequest(identifier: "piatto.\(slot.id).\(id)", content: content, trigger: trigger))
                    }
                }
            }
        }
    }
}

enum DayId {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func string(_ date: Date) -> String { formatter.string(from: date) }
}
