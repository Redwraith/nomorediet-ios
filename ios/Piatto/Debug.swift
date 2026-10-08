import AVFoundation
import HealthKit
import MetricKit
import OSLog
import Photos
import Speech
import SwiftUI
import UserNotifications

/// In-app diagnostics: app events and errors, plus crash reports from earlier runs. Open it by shaking the
/// iPhone or with nomorediet://debug.
final class DebugLog: NSObject, ObservableObject {
    static let shared = DebugLog()

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let level: String
        let source: String
        let text: String
    }

    @Published private(set) var entries: [Entry] = []
    private static let os = Logger(subsystem: "app.piatto.ios", category: "debug")
    private let limit = 500
    private static let crashKey = "debug.crashes"

    func add(_ level: String, _ source: String, _ text: String) {
        // Also to the system log, so 3uTools / idevicesyslog show it as "Nomorediet(Nomorediet)".
        let line = "[\(source)] \(text.prefix(1000))"
        if level == "error" { Self.os.error("\(line, privacy: .public)") } else { Self.os.notice("\(line, privacy: .public)") }
        let entry = Entry(date: Date(), level: level, source: source, text: String(text.prefix(2000)))
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > self.limit { self.entries.removeFirst(self.entries.count - self.limit) }
        }
    }

    func clear() { DispatchQueue.main.async { self.entries.removeAll() } }

    /// Crash summaries iOS delivered through MetricKit (they arrive on the launch after the crash).
    var crashes: [String] { UserDefaults.standard.stringArray(forKey: Self.crashKey) ?? [] }

    func startCrashReports() {
        MXMetricManager.shared.add(self)
        // Objective-C exceptions: keep the reason so it shows up on the next launch.
        NSSetUncaughtExceptionHandler { exception in
            DebugLog.storeCrash("Eccezione \(exception.name.rawValue): \(exception.reason ?? "")\n"
                + exception.callStackSymbols.prefix(12).joined(separator: "\n"))
        }
    }

    fileprivate static func storeCrash(_ text: String) {
        var list = UserDefaults.standard.stringArray(forKey: crashKey) ?? []
        list.insert("\(Date().formatted(date: .abbreviated, time: .standard))\n\(text)", at: 0)
        UserDefaults.standard.set(Array(list.prefix(10)), forKey: crashKey)
    }

    func clearCrashes() {
        UserDefaults.standard.removeObject(forKey: Self.crashKey)
        objectWillChange.send()
    }

    func report(status: [(String, String)]) -> String {
        let time = Date.FormatStyle(date: .omitted, time: .standard)
        var out = "Nomorediet \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?")"
            + " (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?"))"
            + " · iOS \(UIDevice.current.systemVersion) · \(Self.model)\n\n"
        out += status.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        if !crashes.isEmpty { out += "\n\n— Crash —\n" + crashes.joined(separator: "\n\n") }
        out += "\n\n— Log —\n" + entries.map { "\($0.date.formatted(time)) [\($0.level)] \($0.source): \($0.text)" }
            .joined(separator: "\n")
        return out
    }

    static var model: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

extension DebugLog: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                var text = "Crash"
                if let type = crash.exceptionType { text += " tipo \(type)" }
                if let signal = crash.signal { text += " segnale \(signal)" }
                if let reason = crash.terminationReason { text += "\n\(reason)" }
                if let objc = crash.exceptionReason { text += "\n\(objc.className): \(objc.composedMessage)" }
                if let tree = String(data: crash.callStackTree.jsonRepresentation(), encoding: .utf8) {
                    text += "\n" + tree.prefix(1500)
                }
                DebugLog.storeCrash(text)
            }
            for hang in payload.hangDiagnostics ?? [] {
                DebugLog.storeCrash("Blocco dell'interfaccia di \(hang.hangDuration.formatted())")
            }
        }
        DispatchQueue.main.async { self.objectWillChange.send() }
    }
}

struct DebugView: View {
    @ObservedObject var log = DebugLog.shared
    @State private var status: [(String, String)] = []
    @State private var filter = "tutti"
    @State private var copied = false
    let close: () -> Void

    private var shown: [DebugLog.Entry] {
        let list = filter == "errori" ? log.entries.filter { $0.level == "error" || $0.level == "warn" } : log.entries
        return list.reversed()
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Stato") {
                    ForEach(status.indices, id: \.self) { index in
                        let row = status[index]
                        HStack {
                            Text(row.0)
                            Spacer()
                            Text(row.1).foregroundStyle(row.1.hasPrefix("✓") ? .green : row.1.hasPrefix("✗") ? .red : .secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        .font(.footnote)
                    }
                }
                if !log.crashes.isEmpty {
                    Section {
                        ForEach(log.crashes, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                        Button("Cancella crash", role: .destructive) { log.clearCrashes() }
                    } header: { Text("Crash precedenti") }
                }
                Section {
                    Picker("Filtro", selection: $filter) {
                        Text("Tutti").tag("tutti")
                        Text("Errori e avvisi").tag("errori")
                    }
                    .pickerStyle(.segmented)
                    if shown.isEmpty { Text("Nessun messaggio").foregroundStyle(.secondary) }
                    ForEach(shown) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entry.date.formatted(date: .omitted, time: .standard)) · \(entry.source) · \(entry.level)")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(entry.text).font(.caption.monospaced()).textSelection(.enabled)
                                .foregroundStyle(entry.level == "error" ? .red : entry.level == "warn" ? .orange : .primary)
                        }
                    }
                } header: { Text("Console (\(log.entries.count))") }
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Chiudi", action: close) }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { UIPasteboard.general.string = log.report(status: status); copied = true } label: {
                        Label(copied ? "Copiato" : "Copia", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    ShareLink(item: log.report(status: status)) { Label("Condividi", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) { log.clear() } label: { Label("Svuota", systemImage: "trash") }
                }
            }
            .task { status = await DebugStatus.collect() }
            .refreshable { status = await DebugStatus.collect() }
        }
    }
}

@MainActor
enum DebugStatus {
    static func collect() async -> [(String, String)] {
        func av(_ type: AVMediaType) -> String {
            switch AVCaptureDevice.authorizationStatus(for: type) {
            case .authorized: return "✓ consentito"
            case .denied, .restricted: return "✗ negato"
            default: return "non ancora chiesto"
            }
        }
        var rows: [(String, String)] = []
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        rows.append(("App", "\(version) (\(build))"))
        rows.append(("iOS", "\(UIDevice.current.systemVersion) · \(DebugLog.model)"))
        rows.append(("Bundle", Bundle.main.bundleIdentifier ?? "?"))
        rows.append(("Fotocamera", av(.video)))
        rows.append(("Microfono", av(.audio)))
        rows.append(("Riconoscimento vocale", {
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return "✓ consentito"
            case .denied, .restricted: return "✗ negato"
            default: return "non ancora chiesto"
            }
        }()))
        rows.append(("Foto", {
            switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
            case .authorized, .limited: return "✓ consentito"
            case .denied, .restricted: return "✗ negato"
            default: return "non ancora chiesto"
            }
        }()))
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        rows.append(("Notifiche", {
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: return "✓ consentite"
            case .denied: return "✗ negate"
            default: return "non ancora chiesto"
            }
        }()))
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        rows.append(("Promemoria in coda", "\(pending.count)"))
        if HKHealthStore.isHealthDataAvailable() {
            let status = try? await HKHealthStore().statusForAuthorizationRequest(toShare: [], read: [HKQuantityType(.bodyMass)])
            rows.append(("Apple Salute", status == .unnecessary ? "✓ permesso già chiesto" : status == nil ? "✗ errore (firma senza HealthKit?)" : "non ancora chiesto"))
        } else {
            rows.append(("Apple Salute", "✗ non disponibile"))
        }
        let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStore.groupID) != nil
        rows.append(("App Group (widget)", group ? "✓ attivo" : "✗ assente: il widget non riceve dati"))
        return rows
    }
}
