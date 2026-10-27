import BackgroundTasks
import Foundation

/// Over-the-air updates of the food database: every 7 days the app downloads the products sold in Italy that
/// were added or changed on Open Food Facts since the last update and stores them in `FoodStore`'s updates
/// database. Runs as a background task (when iOS allows it, usually overnight on Wi-Fi and charging) and, as a
/// fallback, when the app is opened after more than 7 days. Bounded: at most `maxPages` requests per run,
/// spaced to respect Open Food Facts' rate limit.
enum FoodUpdater {
    static let taskID = "app.piatto.ios.fooddb"
    private static let lastKey = "fooddb.lastUpdate"
    private static let cursorKey = "fooddb.cursor"
    private static let interval: TimeInterval = 7 * 86400
    private static let maxPages = 30
    private static let spacing: Duration = .seconds(7)
    /// A failed run (Open Food Facts down or overloaded) is not retried by the foreground fallback for this long,
    /// otherwise every time the app comes to the front would hit the server again.
    private static let failedKey = "fooddb.lastFailure"
    private static let retryCooldown: TimeInterval = 6 * 3600
    private static let pageAttempts = 3
    private static var running = false

    static var lastUpdate: Date? { UserDefaults.standard.object(forKey: lastKey) as? Date }

    /// Call once at launch, before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            let work = Task { await run(); task.setTaskCompleted(success: true) }
            task.expirationHandler = { work.cancel() }
            schedule()
        }
    }

    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: taskID)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = (lastUpdate ?? .distantPast).addingTimeInterval(interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Foreground fallback: updates when the last run is older than 7 days and the last attempt did not fail
    /// less than 6 hours ago.
    static func updateIfNeeded() {
        let failure = UserDefaults.standard.object(forKey: failedKey) as? Date
        guard shouldUpdate(now: Date(), lastUpdate: lastUpdate, lastFailure: failure) else { return }
        Task.detached(priority: .background) { await run() }
    }

    static func shouldUpdate(now: Date, lastUpdate: Date?, lastFailure: Date?) -> Bool {
        guard now.timeIntervalSince(lastUpdate ?? .distantPast) > interval else { return false }
        if let lastFailure, now.timeIntervalSince(lastFailure) < retryCooldown { return false }
        return true
    }

    /// One page, retried up to `pageAttempts` times with growing waits (5 s, 20 s) when the server errors out.
    private static func fetchPage(_ page: Int) async throws -> (foods: [Food], oldest: Double?) {
        var attempt = 1
        while true {
            do {
                return try await OpenFoodFacts.recentlyModifiedInItaly(page: page)
            } catch {
                guard attempt < pageAttempts, !Task.isCancelled else { throw error }
                try await Task.sleep(for: .seconds(5 * attempt * attempt))
                attempt += 1
            }
        }
    }

    /// Downloads changed products newest first until it reaches the previous update (or the build date of the
    /// bundled copy the first time).
    @discardableResult
    static func run() async -> Int {
        guard !running else { return 0 }
        running = true
        defer { running = false }
        let defaults = UserDefaults.standard
        let since = defaults.double(forKey: cursorKey).nonZero ?? builtTimestamp()
        let started = Date().timeIntervalSince1970
        var saved = 0
        DebugLog.shared.add("info", "db", "Aggiornamento database: prodotti modificati dopo \(Date(timeIntervalSince1970: since).formatted(date: .abbreviated, time: .omitted))")
        for page in 1...maxPages {
            if Task.isCancelled { break }
            do {
                let result = try await fetchPage(page)
                FoodStore.shared.upsert(result.foods)
                saved += result.foods.count
                guard let oldest = result.oldest, oldest > since, !result.foods.isEmpty else { break }
            } catch {
                if !Task.isCancelled { defaults.set(Date(), forKey: failedKey) }
                DebugLog.shared.add("warn", "db", "Aggiornamento interrotto, riprovo tra qualche ora: \(error.localizedDescription)")
                return saved
            }
            try? await Task.sleep(for: spacing)
        }
        defaults.set(started, forKey: cursorKey)
        defaults.set(Date(), forKey: lastKey)
        defaults.removeObject(forKey: failedKey)
        DebugLog.shared.add("info", "db", "Aggiornamento database completato: \(saved) prodotti nuovi o modificati")
        return saved
    }

    /// The bundled copy's build date, so the first update fetches only what changed after it.
    private static func builtTimestamp() -> Double {
        guard let built = FoodStore.shared.built, let date = ISO8601DateFormatter.dateOnly.date(from: built) else {
            return Date().addingTimeInterval(-interval).timeIntervalSince1970
        }
        return date.timeIntervalSince1970
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}

private extension ISO8601DateFormatter {
    static let dateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()
}
