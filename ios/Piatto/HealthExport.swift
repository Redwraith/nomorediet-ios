import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Apple Health's own full export (Salute → profilo → "Esporta tutti i dati sanitari" → export.zip → export.xml).
/// It holds every record ever saved, from iPhone and Watch: read in a stream (the file can be hundreds of MB),
/// turned into one value per day, and merged with the data from the Shortcuts automation.
final class HealthExportReader: NSObject, XMLParserDelegate {
    struct Summary {
        /// day → metric → value, same metric names as `ShortcutHealth.metrics`.
        var days: [String: [String: Double]] = [:]
        /// Every weighing, day → kg.
        var weights: [String: Double] = [:]
        var records = 0
    }

    /// Records summed per day (steps, energy, distance, minutes, flights).
    private static let summed: [String: String] = [
        "HKQuantityTypeIdentifierStepCount": "steps",
        "HKQuantityTypeIdentifierActiveEnergyBurned": "activeKcal",
        "HKQuantityTypeIdentifierBasalEnergyBurned": "basalKcal",
        "HKQuantityTypeIdentifierDistanceWalkingRunning": "km",
        "HKQuantityTypeIdentifierAppleExerciseTime": "exerciseMin",
        "HKQuantityTypeIdentifierFlightsClimbed": "flights",
    ]
    /// Records averaged per day.
    private static let averaged: [String: String] = [
        "HKQuantityTypeIdentifierHeartRate": "heartRate",
        "HKQuantityTypeIdentifierRestingHeartRate": "restingHR",
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN": "hrv",
    ]
    /// Records where the day's last value counts.
    private static let last: [String: String] = [
        "HKQuantityTypeIdentifierBodyMass": "weightKg",
        "HKQuantityTypeIdentifierVO2Max": "vo2max",
        "HKQuantityTypeIdentifierBodyFatPercentage": "bodyFat",
    ]
    private static let sleepType = "HKCategoryTypeIdentifierSleepAnalysis"

    private let since: String
    /// day → metric → source → sum. iPhone and Watch both count the same steps: Health keeps one of them,
    /// so per day the source with the most is used instead of adding them up.
    private var sums: [String: [String: [String: Double]]] = [:]
    private var means: [String: [String: (total: Double, count: Int)]] = [:]
    private var lasts: [String: [String: (time: String, value: Double)]] = [:]
    private var summary = Summary()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    /// `since`: oldest day kept for the daily values (weights are always kept, all of them).
    init(since: String) { self.since = since }

    static func read(_ url: URL, since: String) -> Summary? {
        guard let stream = InputStream(url: url) else { return nil }
        let reader = HealthExportReader(since: since)
        let parser = XMLParser(stream: stream)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse() || reader.summary.records > 0 else { return nil }
        return reader.finish()
    }

    /// For tests: the same reading from XML text.
    static func read(xml: String, since: String) -> Summary {
        let reader = HealthExportReader(since: since)
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = reader
        parser.parse()
        return reader.finish()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String]) {
        guard name == "Record", let type = a["type"], let start = a["startDate"], start.count >= 10 else { return }
        let day = String(start.prefix(10))
        let source = a["sourceName"] ?? ""
        if type == Self.sleepType {
            // asleep (core, deep, REM, unspecified), not "in bed" or "awake"; counted on the day you wake up
            guard let value = a["value"], value.contains("Asleep"), let end = a["endDate"], end.count >= 10,
                  let s = Self.dateFormatter.date(from: start), let e = Self.dateFormatter.date(from: end) else { return }
            let wake = String(end.prefix(10))
            guard wake >= since else { return }
            sums[wake, default: [:]]["sleepHours", default: [:]][source, default: 0] += e.timeIntervalSince(s) / 3600
            summary.records += 1
            return
        }
        guard let text = a["value"], var value = Double(text) else { return }
        let unit = a["unit"] ?? ""
        if let metric = Self.summed[type] {
            guard day >= since else { return }
            value = Self.convert(value, unit: unit, metric: metric)
            sums[day, default: [:]][metric, default: [:]][source, default: 0] += value
        } else if let metric = Self.averaged[type] {
            guard day >= since else { return }
            let old = means[day]?[metric] ?? (0, 0)
            means[day, default: [:]][metric] = (old.total + value, old.count + 1)
        } else if let metric = Self.last[type] {
            value = Self.convert(value, unit: unit, metric: metric)
            // the export is in time order: the day's last weighing wins
            if metric == "weightKg" { summary.weights[day] = value }
            guard day >= since else {
                summary.records += 1
                return
            }
            if (lasts[day]?[metric]?.time ?? "") <= start { lasts[day, default: [:]][metric] = (start, value) }
        } else {
            return
        }
        summary.records += 1
    }

    /// Health stores energy in kcal or kJ, distance in km, m or miles, weight in kg or lb, body fat as a fraction.
    static func convert(_ value: Double, unit: String, metric: String) -> Double {
        switch (metric, unit) {
        case (_, "kJ"): value / 4.184
        case ("km", "m"): value / 1000
        case ("km", "mi"): value * 1.609344
        case ("weightKg", "lb"): value * 0.45359237
        case ("weightKg", "g"): value / 1000
        case ("bodyFat", _) where value <= 1: value * 100
        default: value
        }
    }

    private func finish() -> Summary {
        for (day, metrics) in sums {
            for (metric, bySource) in metrics { summary.days[day, default: [:]][metric] = bySource.values.max() }
        }
        for (day, metrics) in means {
            for (metric, m) in metrics where m.count > 0 { summary.days[day, default: [:]][metric] = m.total / Double(m.count) }
        }
        for (day, metrics) in lasts {
            for (metric, v) in metrics { summary.days[day, default: [:]][metric] = v.value }
        }
        return summary
    }
}

extension ShortcutHealth {
    /// Merges a whole export: the daily values of the last year, every weighing into the weight history.
    @MainActor
    static func importExport(_ summary: HealthExportReader.Summary, context: ModelContext) -> String {
        var all = history
        for (day, row) in summary.days {
            var merged = all[day] ?? [:]
            for (metric, value) in row where value >= 0 { merged[metric] = value }
            all[day] = merged
        }
        let oldest = DayId.shift(DayId.today, by: -keptDays)
        history = all.filter { $0.key >= oldest }
        let known = Set(((try? context.fetch(FetchDescriptor<WeightEntry>())) ?? []).map(\.day))
        var added = 0
        for (day, kg) in summary.weights where !known.contains(day) {
            context.insert(WeightEntry(day: day, kg: (kg * 10).rounded() / 10, source: "Salute"))
            added += 1
        }
        Sync.applyHealth(result(), context: context)
        HealthCache.shared.status = statusText
        let days = summary.days.count
        return "Importati \(days) giorni di dati da Salute (\(summary.records.formatted()) misurazioni) e \(added) pesate nuove."
    }
}

/// Profilo → Apple Salute → "Importa tutto da Salute": picks export.xml and merges it.
struct HealthExportImportView: View {
    @Environment(\.modelContext) private var context
    @State private var picking = false
    @State private var working = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Text("L'app Salute può esportare tutti i tuoi dati in un file. Nomorediet lo legge tutto: passi, calorie, distanza, minuti di esercizio, piani, sonno, battito, HRV, VO₂ max, grasso corporeo e tutte le pesate di sempre, da iPhone e Apple Watch.")
                    .font(.subheadline)
            }
            Section("Come fare") {
                Label("Apri Salute e tocca la tua foto in alto a destra", systemImage: "1.circle")
                Label("Scorri in fondo: \"Esporta tutti i dati sanitari\" → Esporta (ci vuole qualche minuto)", systemImage: "2.circle")
                Label("Salva il file in File (es. In questo iPhone)", systemImage: "3.circle")
                Label("Nell'app File tocca export.zip: diventa una cartella apple_health_export", systemImage: "4.circle")
                Label("Qui sotto scegli export.xml dentro quella cartella", systemImage: "5.circle")
            }
            .font(.subheadline)
            Section {
                if working {
                    HStack { ProgressView(); Text("Leggo i dati di Salute…").foregroundStyle(.secondary) }
                } else {
                    Button { picking = true } label: { Label("Scegli export.xml", systemImage: "square.and.arrow.down") }
                        .accessibilityIdentifier("health-export-pick")
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("Il file resta sull'iPhone. Per i giorni successivi bastano la sincronizzazione con Comandi rapidi; rifai l'esportazione quando vuoi recuperare tutto.")
            }
        }
        .navigationTitle("Importa da Salute")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.xml, .zip, .data]) { result in
            guard case .success(let url) = result else { return }
            importFile(url)
        }
    }

    private func importFile(_ url: URL) {
        if url.pathExtension.lowercased() == "zip" {
            message = "Questo è lo zip: aprilo prima nell'app File (si estrae con un tocco) e scegli export.xml dentro la cartella."
            return
        }
        working = true
        message = nil
        let since = DayId.shift(DayId.today, by: -ShortcutHealth.keptDays)
        Task {
            let access = url.startAccessingSecurityScopedResource()
            let summary = await Task.detached(priority: .userInitiated) { HealthExportReader.read(url, since: since) }.value
            if access { url.stopAccessingSecurityScopedResource() }
            working = false
            guard let summary, summary.records > 0 else {
                message = "Non trovo dati di Salute in questo file: scegli export.xml (non export_cda.xml)."
                return
            }
            message = ShortcutHealth.importExport(summary, context: context)
            DebugLog.shared.add("info", "health", message ?? "")
        }
    }
}
