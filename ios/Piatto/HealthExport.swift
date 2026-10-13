import Foundation
import Compression
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
                Label("Nel foglio di condivisione che si apre tocca Nomorediet: l'importazione parte da sola", systemImage: "3.circle")
                Label("Oppure salvalo in File e qui sotto scegli export.zip (o export.xml)", systemImage: "4.circle")
            }
            .font(.subheadline)
            Section {
                if working {
                    HStack { ProgressView(); Text("Leggo i dati di Salute…").foregroundStyle(.secondary) }
                } else {
                    Button { picking = true } label: { Label("Scegli export.zip o export.xml", systemImage: "square.and.arrow.down") }
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
        working = true
        message = nil
        let since = DayId.shift(DayId.today, by: -ShortcutHealth.keptDays)
        Task {
            let access = url.startAccessingSecurityScopedResource()
            let summary = await Task.detached(priority: .userInitiated) { HealthExportReader.read(file: url, since: since) }.value
            if access { url.stopAccessingSecurityScopedResource() }
            working = false
            guard let summary, summary.records > 0 else {
                message = "Non trovo dati di Salute in questo file: scegli export.zip o export.xml (non export_cda.xml)."
                return
            }
            message = ShortcutHealth.importExport(summary, context: context)
            DebugLog.shared.add("info", "health", message ?? "")
        }
    }
}

/// Just enough of the ZIP format to take export.xml out of Health's export.zip, in a stream (the file can be
/// gigabytes): central directory (ZIP64 too), then the entry inflated chunk by chunk to a file.
enum ZipReader {
    enum Failure: Error { case notZip, missing(String), unsupported }

    private struct Entry { var name: String; var method: UInt16; var compressed: UInt64; var size: UInt64; var offset: UInt64 }

    /// Extracts the first entry whose name ends with `suffix` to `destination`.
    static func extract(_ zip: URL, entryEndingWith suffix: String, to destination: URL) throws {
        let file = try FileHandle(forReadingFrom: zip)
        defer { try? file.close() }
        guard let entry = try entries(file).first(where: { $0.name.hasSuffix(suffix) && !$0.name.contains("__MACOSX") }) else {
            throw Failure.missing(suffix)
        }
        try file.seek(toOffset: entry.offset)
        let local = try read(file, 30)
        guard u32(local, 0) == 0x04034b50 else { throw Failure.notZip }
        try file.seek(toOffset: entry.offset + 30 + UInt64(u16(local, 26)) + UInt64(u16(local, 28)))
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        switch entry.method {
        case 0: try copy(file, to: out, count: entry.compressed)
        case 8: try inflate(file, to: out, count: entry.compressed)
        default: throw Failure.unsupported
        }
    }

    private static func entries(_ file: FileHandle) throws -> [Entry] {
        let end = try file.seekToEnd()
        let tailLength = min(end, 65_557)
        try file.seek(toOffset: end - tailLength)
        let tail = try read(file, Int(tailLength))
        guard let eocd = stride(from: tail.count - 22, through: 0, by: -1).first(where: { u32(tail, $0) == 0x06054b50 }) else {
            throw Failure.notZip
        }
        var count = UInt64(u16(tail, eocd + 10))
        var cdOffset = UInt64(u32(tail, eocd + 16))
        // ZIP64: the locator just before the end record points to the ZIP64 end record
        if eocd >= 20, u32(tail, eocd - 20) == 0x07064b50 {
            try file.seek(toOffset: u64(tail, eocd - 20 + 8))
            let z = try read(file, 56)
            if u32(z, 0) == 0x06064b50 { count = u64(z, 32); cdOffset = u64(z, 48) }
        }
        try file.seek(toOffset: cdOffset)
        var list: [Entry] = []
        for _ in 0..<count {
            let h = try read(file, 46)
            guard u32(h, 0) == 0x02014b50 else { break }
            let nameLength = Int(u16(h, 28)), extraLength = Int(u16(h, 30)), commentLength = Int(u16(h, 32))
            let name = String(decoding: try read(file, nameLength), as: UTF8.self)
            let extra = try read(file, extraLength)
            _ = try read(file, commentLength)
            var e = Entry(name: name, method: u16(h, 10), compressed: UInt64(u32(h, 20)), size: UInt64(u32(h, 24)),
                          offset: UInt64(u32(h, 42)))
            // ZIP64 extra field: only the values that are 0xFFFFFFFF above, in this order
            var i = 0
            while i + 4 <= extra.count {
                let id = u16(extra, i), length = Int(u16(extra, i + 2))
                if id == 0x0001 {
                    var p = i + 4
                    if e.size == 0xFFFF_FFFF, p + 8 <= extra.count { e.size = u64(extra, p); p += 8 }
                    if e.compressed == 0xFFFF_FFFF, p + 8 <= extra.count { e.compressed = u64(extra, p); p += 8 }
                    if e.offset == 0xFFFF_FFFF, p + 8 <= extra.count { e.offset = u64(extra, p) }
                }
                i += 4 + length
            }
            list.append(e)
        }
        return list
    }

    private static func copy(_ input: FileHandle, to out: FileHandle, count: UInt64) throws {
        var left = count
        while left > 0 {
            let chunk = try read(input, Int(min(left, 1 << 20)))
            guard !chunk.isEmpty else { break }
            out.write(chunk)
            left -= UInt64(chunk.count)
        }
    }

    /// Raw deflate (what ZIP uses) through the Compression framework's streaming API.
    private static func inflate(_ input: FileHandle, to out: FileHandle, count: UInt64) throws {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Failure.unsupported
        }
        defer { compression_stream_destroy(stream) }
        let outSize = 1 << 20
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: outSize)
        defer { buffer.deallocate() }
        var left = count
        var status = COMPRESSION_STATUS_OK
        while status != COMPRESSION_STATUS_END {
            let chunk = left > 0 ? try read(input, Int(min(left, 1 << 20))) : Data()
            left -= UInt64(chunk.count)
            let finalize = left == 0 || chunk.isEmpty
            var idle = 0
            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                stream.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(buffer)
                stream.pointee.src_size = chunk.count
                while true {
                    stream.pointee.dst_ptr = buffer
                    stream.pointee.dst_size = outSize
                    status = compression_stream_process(stream, finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    guard status != COMPRESSION_STATUS_ERROR else { throw Failure.unsupported }
                    let produced = outSize - stream.pointee.dst_size
                    if produced > 0 { out.write(Data(bytes: buffer, count: produced)) }
                    if status == COMPRESSION_STATUS_END { return }
                    // input used up and room left in the output: wait for the next chunk, unless this is the last one,
                    // where the decoder is called until it says END (it can hold back output between calls)
                    if stream.pointee.src_size == 0 && produced < outSize {
                        if !finalize { return }
                        idle = produced == 0 ? idle + 1 : 0
                        if idle > 2 { return }
                    }
                }
            }
            if finalize { break }
        }
    }

    private static func read(_ file: FileHandle, _ count: Int) throws -> Data {
        count == 0 ? Data() : (try file.read(upToCount: count) ?? Data())
    }
    private static func u16(_ d: Data, _ i: Int) -> UInt16 { UInt16(d[d.startIndex + i]) | UInt16(d[d.startIndex + i + 1]) << 8 }
    private static func u32(_ d: Data, _ i: Int) -> UInt32 { UInt32(u16(d, i)) | UInt32(u16(d, i + 2)) << 16 }
    private static func u64(_ d: Data, _ i: Int) -> UInt64 { UInt64(u32(d, i)) | UInt64(u32(d, i + 4)) << 32 }
}

extension HealthExportReader {
    /// export.xml, or Health's export.zip as it comes out of the share sheet (export.xml is taken out first).
    static func read(file url: URL, since: String) -> Summary? {
        guard url.pathExtension.lowercased() == "zip" else { return read(url, since: since) }
        let xml = FileManager.default.temporaryDirectory.appendingPathComponent("health-export.xml")
        defer { try? FileManager.default.removeItem(at: xml) }
        do { try ZipReader.extract(url, entryEndingWith: "/export.xml", to: xml) } catch {
            do { try ZipReader.extract(url, entryEndingWith: "export.xml", to: xml) } catch { return nil }
        }
        return read(xml, since: since)
    }
}
