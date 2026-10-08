import AppIntents
import Foundation
import UIKit

/// Apple Health through the Shortcuts app. Sideloaded apps (SideStore with a free Apple ID) lose the HealthKit
/// entitlement, so the app cannot read Health itself; a personal automation reads the values with Shortcuts' own
/// Health actions and hands them to the "Invia dati Salute a Nomorediet" action below. Same data, same use.
enum ShortcutHealth {
    private static let key = "health.shortcut.v1"
    private static let sentKey = "health.shortcut.sent"
    static let metrics = ["steps", "activeKcal", "basalKcal", "km", "exerciseMin", "flights", "weightKg", "sleepHours",
                          "restingHR", "heartRate", "hrv", "vo2max", "bodyFat"]
    /// Names of the shortcut: the one in the guide, then the one named after the action.
    static let shortcutNames = ["Nomorediet Salute", "Invia dati Salute a Nomorediet"]
    static var shortcutName: String { shortcutNames[0] }

    /// Runs the user's shortcut through Shortcuts and comes back to the app (x-callback). When the first name does
    /// not exist, Shortcuts calls x-error, which tries the next name.
    static func runShortcut() {
        if let url = runURL(names: shortcutNames) { UIApplication.shared.open(url) }
        DebugLog.shared.add("info", "health", "Avvio il comando rapido \(shortcutName)")
    }

    static func runURL(names: [String]) -> URL? {
        guard let first = names.first else { return URL(string: "nomorediet://diario") }
        let fallback = runURL(names: Array(names.dropFirst()))?.absoluteString ?? "nomorediet://diario"
        var c = URLComponents(string: "shortcuts://x-callback-url/run-shortcut")!
        c.queryItems = [URLQueryItem(name: "name", value: first),
                        URLQueryItem(name: "x-success", value: "nomorediet://diario"),
                        URLQueryItem(name: "x-error", value: fallback)]
        // query values must be fully escaped: the fallback is itself a URL with & and =
        c.percentEncodedQuery = c.queryItems?.map { item in
            "\(item.name)=\(item.value?.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"
        }.joined(separator: "&")
        return c.url
    }

    /// The app cannot read Health itself (installed without the HealthKit entitlement, or never connected).
    static var needsShortcut: Bool {
        hasData || HealthCache.shared.status?.contains("entitlement") == true
    }

    /// day → metric → value, last 60 days.
    static var history: [String: [String: Double]] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Double]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var lastSent: Date? { UserDefaults.standard.object(forKey: sentKey) as? Date }
    static var hasData: Bool { !history.isEmpty }

    /// Merges the values of one day (nil = not sent, kept as it was).
    static func record(day: String, values: [String: Double?]) {
        var all = history
        var row = all[day] ?? [:]
        for (metric, value) in values { if let value, value >= 0 { row[metric] = value } }
        all[day] = row
        let oldest = DayId.shift(DayId.today, by: -60)
        all = all.filter { $0.key >= oldest }
        history = all
        UserDefaults.standard.set(Date(), forKey: sentKey)
    }

    /// The same shape `HealthBridge.fetch` returns, so the rest of the app does not care where the data came from.
    static func result(today: String = DayId.today) -> [String: Any] {
        let all = history
        var daily: [String: [String: Double]] = [:]
        for (day, row) in all {
            for (metric, value) in row where ["steps", "activeKcal", "basalKcal", "km", "exerciseMin", "flights"].contains(metric) {
                daily[metric, default: [:]][day] = value
            }
        }
        let weights = all.compactMap { day, row in row["weightKg"].map { ["date": day, "kg": $0] as [String: Any] } }
            .sorted { ($0["date"] as? String ?? "") < ($1["date"] as? String ?? "") }
        var readiness: [String: Double] = [:]
        if let sleep = all[today]?["sleepHours"] { readiness["sleepHours"] = sleep }
        let rhr = all.filter { $0.key < today }.compactMap { $0.value["restingHR"] }
        if let r = all[today]?["restingHR"] { readiness["rhrToday"] = r }
        if !rhr.isEmpty { readiness["rhrBase"] = rhr.reduce(0, +) / Double(rhr.count) }
        let hrv = all.filter { $0.key < today }.compactMap { $0.value["hrv"] }
        if let h = all[today]?["hrv"] { readiness["hrvToday"] = h }
        if !hrv.isEmpty { readiness["hrvBase"] = hrv.reduce(0, +) / Double(hrv.count) }
        // values that change slowly: the most recent one sent
        var latest: [String: Double] = [:]
        for (metric, key) in [("heartRate", "heartRateAvg"), ("vo2max", "vo2max"), ("bodyFat", "bodyFat")] {
            if let day = all.keys.filter({ all[$0]?[metric] != nil }).max() { latest[key] = all[day]?[metric] }
        }
        return ["available": true, "authorized": true, "weights": weights, "steps": daily["steps"] ?? [:],
                "activeKcal": daily["activeKcal"] ?? [:], "daily": daily, "latest": latest,
                "workouts": [[String: Any]](), "readiness": readiness, "date": today]
    }

    /// `nomorediet://health?steps=8532&active=512&basal=1790&weight=84,6&sleep=7,5` from the downloadable shortcut.
    /// Shortcuts turns numbers into text with the phone's locale ("8.532", "84,6"), so both are understood.
    static func handle(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let names = ["steps": "steps", "active": "activeKcal", "basal": "basalKcal", "weight": "weightKg",
                     "sleep": "sleepHours", "km": "km", "exercise": "exerciseMin", "rhr": "restingHR", "flights": "flights",
                     "hr": "heartRate", "hrv": "hrv", "vo2": "vo2max", "fat": "bodyFat"]
        var values: [String: Double?] = [:]
        for item in items {
            guard let metric = names[item.name], let text = item.value else { continue }
            var value = number(text, decimals: ["weightKg", "sleepHours", "km", "vo2max", "bodyFat"].contains(metric))
            // Health gives body fat as a fraction (0,22) in some locales
            if metric == "bodyFat", let v = value, v < 1 { value = v * 100 }
            values[metric] = value
        }
        guard !values.isEmpty else { return }
        record(day: DayId.today, values: values)
        Sync.applyHealth(result(), context: nil)
        HealthCache.shared.status = statusText
        DebugLog.shared.add("info", "health", "Dati Salute ricevuti dal comando rapido: \(values.compactMapValues { $0 })")
    }

    /// The first number in a text written in any locale: "8.532 passi" → 8532, "84,6 kg" → 84.6, "1,790.5" → 1790.5.
    /// Counts (steps, kcal) read a lone separator followed by exactly three digits as thousands.
    static func number(_ text: String, decimals: Bool) -> Double? {
        guard let match = text.firstMatch(of: /[0-9][0-9.,\u{00A0}\u{202F}' ]*/) else { return nil }
        var raw = String(match.output).filter { "0123456789.,".contains($0) }
        while let last = raw.last, last == "." || last == "," { raw.removeLast() }
        let dots = raw.filter { $0 == "." }.count, commas = raw.filter { $0 == "," }.count
        if dots > 0 && commas > 0 {
            // the separator that comes last is the decimal one
            let decimal: Character = raw.lastIndex(of: ".")! > raw.lastIndex(of: ",")! ? "." : ","
            raw = raw.filter { $0 != (decimal == "." ? "," : ".") }.replacingOccurrences(of: String(decimal), with: ".")
        } else if dots + commas > 1 {
            raw = raw.filter { $0.isNumber }  // 1.234.567
        } else if dots + commas == 1 {
            let separator: Character = dots == 1 ? "." : ","
            let after = raw.split(separator: separator, omittingEmptySubsequences: false).last?.count ?? 0
            raw = (!decimals && after == 3) ? raw.filter { $0.isNumber } : raw.replacingOccurrences(of: ",", with: ".")
        }
        return Double(raw)
    }

    static var statusText: String {
        guard let lastSent else { return "Collegata tramite Comandi rapidi ✓" }
        let when = Calendar.current.isDateInToday(lastSent)
            ? "oggi alle " + lastSent.formatted(.dateTime.hour().minute())
            : lastSent.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "it_IT")))
        return "Collegata tramite Comandi rapidi ✓ · ultimo invio \(when)"
    }
}

/// Shortcuts action: Health values in, nothing opened. Every field takes the output of "Trova campioni di Salute"
/// directly (a list of samples, read as numbers) or a single number: the app adds up counts (steps, kcal, km,
/// minutes, flights), averages rates (heart rate, HRV) and keeps the latest reading (weight, body fat, VO2 max).
struct SendHealthIntent: AppIntent {
    static var title: LocalizedStringResource = "Invia dati Salute a Nomorediet"
    static var description = IntentDescription(
        "Passa a Nomorediet i dati di Apple Salute di oggi. In ogni campo metti il risultato di \"Trova campioni di Salute\" (data di inizio: oggi).")
    static var openAppWhenRun = false

    @Parameter(title: "Passi") var steps: [Double]?
    @Parameter(title: "Calorie attive (kcal)") var activeKcal: [Double]?
    @Parameter(title: "Calorie a riposo (kcal)") var basalKcal: [Double]?
    @Parameter(title: "Peso (kg)") var weightKg: [Double]?
    @Parameter(title: "Ore di sonno") var sleepHours: [Double]?
    @Parameter(title: "Distanza (km)") var km: [Double]?
    @Parameter(title: "Minuti di esercizio") var exerciseMin: [Double]?
    @Parameter(title: "Battito a riposo") var restingHR: [Double]?
    @Parameter(title: "Battito medio") var heartRate: [Double]?
    @Parameter(title: "HRV (ms)") var hrv: [Double]?
    @Parameter(title: "VO2 max") var vo2max: [Double]?
    @Parameter(title: "Grasso corporeo (%)") var bodyFat: [Double]?
    @Parameter(title: "Piani saliti") var flights: [Double]?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        typealias A = ShortcutHealth.Aggregate
        let values: [String: Double?] = [
            "steps": A.sum(steps), "activeKcal": A.sum(activeKcal), "basalKcal": A.sum(basalKcal),
            "km": A.sum(km), "exerciseMin": A.sum(exerciseMin), "flights": A.sum(flights),
            "sleepHours": A.sleep(sleepHours), "heartRate": A.mean(heartRate), "hrv": A.mean(hrv),
            "restingHR": A.latest(restingHR), "weightKg": A.latest(weightKg), "vo2max": A.latest(vo2max),
            "bodyFat": A.latest(bodyFat).map { $0 < 1 ? $0 * 100 : $0 },
        ]
        let received = values.compactMapValues { $0 }
        guard !received.isEmpty else {
            DebugLog.shared.add("error", "health", "Comando rapido senza dati: nessun campo collegato")
            return .result(dialog: "Nomorediet non ha ricevuto dati: tocca i campi dell'azione (Passi, Calorie…) e scegli il risultato di \"Trova campioni di Salute\".")
        }
        ShortcutHealth.record(day: DayId.today, values: values)
        Sync.applyHealth(ShortcutHealth.result(), context: nil)
        HealthCache.shared.status = ShortcutHealth.statusText
        DebugLog.shared.add("info", "health", "Dati Salute ricevuti da Comandi rapidi: \(received)")
        var parts: [String] = []
        if let v = received["steps"] { parts.append("\(Int(v)) passi") }
        if let v = received["activeKcal"] { parts.append("\(Int(v)) kcal attive") }
        if let v = received["weightKg"] { parts.append(String(format: "%.1f kg", v).replacingOccurrences(of: ".", with: ",")) }
        let others = received.count - parts.count
        if others > 0 { parts.append("\(others) altri valori") }
        return .result(dialog: IntentDialog(stringLiteral: "Ricevuto: " + parts.joined(separator: ", ") + "."))
    }
}

extension ShortcutHealth {
    /// How a list of Health samples becomes one value for the day.
    enum Aggregate {
        static func sum(_ v: [Double]?) -> Double? {
            guard let v, !v.isEmpty else { return nil }
            return v.reduce(0, +)
        }
        static func mean(_ v: [Double]?) -> Double? {
            guard let v, !v.isEmpty else { return nil }
            return v.reduce(0, +) / Double(v.count)
        }
        /// One reading (limit 1 in Shortcuts) is used as is; several readings of the same day are averaged.
        static func latest(_ v: [Double]?) -> Double? {
            guard let v, !v.isEmpty else { return nil }
            return v.count == 1 ? v[0] : mean(v)
        }
        /// Sleep arrives as hours, or as seconds/minutes when a duration is passed: normalised to hours.
        static func sleep(_ v: [Double]?) -> Double? {
            guard let total = sum(v) else { return nil }
            if total > 24 * 60 { return total / 3600 }
            if total > 24 { return total / 60 }
            return total
        }
    }
}
