import SwiftUI
import UserNotifications

/// Daily supplement reminders: a multivitamin every morning, and 5 g of creatine — after the workout on
/// training days, in the morning on rest days. Each one can be marked as taken from the notification
/// ("Presa ✓") or from the Today screen, which cancels the rest of that day's reminders.
enum Supplements {
    enum Kind: String, CaseIterable, Identifiable {
        case multi, creatine
        var id: String { rawValue }
        var title: String { self == .multi ? "Multivitaminico" : "Creatina 5 g" }
        var icon: String { self == .multi ? "pills.fill" : "bolt.fill" }
    }

    static let category = "SUPPLEMENT"
    static let takenAction = "SUPPLEMENT_TAKEN"
    private static let defaults = UserDefaults.standard

    static var enabled: Bool {
        get { defaults.object(forKey: "supp.enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "supp.enabled"); reschedule() }
    }
    /// Morning time for the multivitamin and for creatine on rest days, "HH:mm".
    static var morning: String {
        get { defaults.string(forKey: "supp.morning") ?? "08:00" }
        set { defaults.set(newValue, forKey: "supp.morning"); reschedule() }
    }
    /// Safety net on training days if creatine was not marked after the workout.
    static var evening: String {
        get { defaults.string(forKey: "supp.evening") ?? "21:00" }
        set { defaults.set(newValue, forKey: "supp.evening"); reschedule() }
    }

    static func isTaken(_ kind: Kind, day: String = DayId.today) -> Bool { defaults.bool(forKey: "supp.\(kind.rawValue).\(day)") }
    static var creatineTakenToday: Bool { isTaken(.creatine) }

    static func setTaken(_ kind: Kind, _ taken: Bool, day: String = DayId.today) {
        defaults.set(taken, forKey: "supp.\(kind.rawValue).\(day)")
        if taken {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids(kind, day: day))
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids(kind, day: day))
        } else {
            reschedule()
        }
    }

    /// Creatine is taken after training when today is (or turned out to be) a training day.
    static func isTrainingDay(_ day: String) -> Bool {
        defaults.bool(forKey: "trained.\(day)") || DayKind.of(day, saved: nil) == .training
    }

    /// Called when a set is logged: today becomes a training day for the reminders.
    static func markTrained() {
        guard !defaults.bool(forKey: "trained.\(DayId.today)") else { return }
        defaults.set(true, forKey: "trained.\(DayId.today)")
        reschedule()
    }

    /// "Termina allenamento" or leaving the gym: creatine now, unless already taken.
    static func workoutFinished() {
        markTrained()
        guard enabled, !isTaken(.creatine) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Creatina 💪"
        content.body = "Allenamento finito: prendi adesso i 5 g di creatina."
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = ["kind": Kind.creatine.rawValue, "day": DayId.today]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "supp.creatine.\(DayId.today).post", content: content, trigger: trigger))
    }

    static func registerCategory() {
        let taken = UNNotificationAction(identifier: takenAction, title: "Presa ✓", options: [])
        let supplement = UNNotificationCategory(identifier: category, actions: [taken], intentIdentifiers: [])
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            center.setNotificationCategories(existing.filter { $0.identifier != category }.union([supplement]))
        }
    }

    /// Handles "Presa ✓" from a notification. Returns true if it was a supplement notification.
    @discardableResult
    static func handle(_ response: UNNotificationResponse) -> Bool {
        let info = response.notification.request.content.userInfo
        guard response.notification.request.content.categoryIdentifier == category,
              let raw = info["kind"] as? String, let kind = Kind(rawValue: raw) else { return false }
        if response.actionIdentifier == takenAction { setTaken(kind, true, day: info["day"] as? String ?? DayId.today) }
        return true
    }

    private static func ids(_ kind: Kind, day: String) -> [String] {
        ["supp.\(kind.rawValue).\(day).morning", "supp.\(kind.rawValue).\(day).evening", "supp.\(kind.rawValue).\(day).post"]
    }

    /// The next 7 days of reminders, skipping what is already taken.
    static func reschedule() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter {
                $0.hasPrefix("supp.") && !$0.hasSuffix(".post")
            })
            guard enabled else { return }
            let cal = Calendar.current
            let now = Date()
            for offset in 0..<7 {
                guard let date = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now)) else { continue }
                let day = DayId.string(date)
                let training = isTrainingDay(day)
                if !isTaken(.multi, day: day) {
                    add(.multi, day: day, slot: "morning", time: morning, date: date, now: now,
                        body: "È ora del multivitaminico: prendilo con la colazione.")
                }
                if !isTaken(.creatine, day: day) {
                    if training {
                        add(.creatine, day: day, slot: "evening", time: evening, date: date, now: now,
                            body: "Hai preso la creatina dopo l'allenamento? Se no, prendi ora i 5 g.")
                    } else {
                        add(.creatine, day: day, slot: "morning", time: morning, date: date, now: now,
                            body: "Giorno di riposo: prendi 5 g di creatina stamattina.")
                    }
                }
            }
        }
    }

    private static func add(_ kind: Kind, day: String, slot: String, time: String, date: Date, now: Date, body: String) {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return }
        let cal = Calendar.current
        var when = cal.dateComponents([.year, .month, .day], from: date)
        when.hour = parts[0]
        when.minute = parts[1]
        guard let fire = cal.date(from: when), fire > now else { return }
        let content = UNMutableNotificationContent()
        content.title = kind.title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = ["kind": kind.rawValue, "day": day]
        let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "supp.\(kind.rawValue).\(day).\(slot)", content: content, trigger: trigger))
    }
}

/// Today screen: tap to mark the supplements as taken.
struct SupplementsCard: View {
    @State private var refresh = 0

    var body: some View {
        let training = Supplements.isTrainingDay(DayId.today)
        VStack(alignment: .leading, spacing: 10) {
            Text("Integratori di oggi").font(.headline)
            HStack(spacing: 10) {
                ForEach(Supplements.Kind.allCases) { kind in
                    let taken = Supplements.isTaken(kind)
                    Button {
                        Supplements.setTaken(kind, !taken)
                        refresh += 1
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(kind.title, systemImage: taken ? "checkmark.circle.fill" : kind.icon)
                                .font(.subheadline.weight(.semibold))
                            Text(taken ? "Presa" : kind == .multi ? "Con la colazione" : training ? "Dopo l'allenamento" : "Stamattina")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(taken ? Theme.accent.opacity(0.18) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(taken ? .isSelected : [])
                }
            }
            .id(refresh)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }
}

/// Settings in the Coach reminders card.
struct SupplementSettings: View {
    @State private var enabled = Supplements.enabled
    @State private var morning = Supplements.morning
    @State private var evening = Supplements.evening

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $enabled) { Text("Integratori").font(.headline) }
                .onChange(of: enabled) { _, on in Supplements.enabled = on }
            if enabled {
                DatePicker("Mattina (multivitaminico)", selection: time($morning) { Supplements.morning = $0 }, displayedComponents: .hourAndMinute)
                DatePicker("Sera, se manca la creatina", selection: time($evening) { Supplements.evening = $0 }, displayedComponents: .hourAndMinute)
                Text("Creatina 5 g: nei giorni di allenamento te la ricordo appena finisci (\"Termina allenamento\" o quando esci dalla palestra), nei giorni di riposo al mattino.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func time(_ text: Binding<String>, save: @escaping (String) -> Void) -> Binding<Date> {
        Binding(
            get: {
                let p = text.wrappedValue.split(separator: ":").compactMap { Int($0) }
                return Calendar.current.date(bySettingHour: p.first ?? 8, minute: p.last ?? 0, second: 0, of: .now) ?? .now
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                text.wrappedValue = String(format: "%02d:%02d", c.hour ?? 8, c.minute ?? 0)
                save(text.wrappedValue)
            })
    }
}
