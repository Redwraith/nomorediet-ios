import Foundation
import UserNotifications

/// Limits and accounting for every AI call: kill switch, monthly budget, daily call cap,
/// one request at a time, cost tracking from the API's token usage, and a log.
/// No AI request may run without passing `begin()`.
@MainActor
final class AIGuard: ObservableObject {
    static let shared = AIGuard()

    // Claude Opus 5.5 list prices, USD per million tokens.
    static let inputPerMTok = 4.0
    static let outputPerMTok = 20.0
    /// Hard limits that settings cannot raise.
    static let maxDailyCallsCeiling = 100
    static let maxMonthlyBudgetCeiling = 50.0
    static let maxAttempts = 3

    enum Engine: String, Codable, CaseIterable { case apple, gemini, claude }

    struct Settings: Codable, Equatable {
        var enabled = true
        var engine = Engine.apple
        var monthlyBudgetUSD = 5.0
        var dailyMaxCalls = 25
    }

    struct Call: Codable, Identifiable, Hashable {
        var id = UUID()
        var date: Date
        var inputTokens: Int
        var outputTokens: Int
        var costUSD: Double
        var outcome: String
    }

    enum Block: LocalizedError {
        case disabled, budget(Double), daily(Int), busy
        var errorDescription: String? {
            switch self {
            case .disabled: "L'analisi AI è spenta (Profilo → Analisi AI → Interruttore)."
            case .budget(let b): "Hai raggiunto il budget AI del mese (\(b.it(2)) $). Alzalo in Profilo → Analisi AI o aspetta il mese prossimo."
            case .daily(let n): "Hai fatto \(n) analisi oggi, il massimo impostato. Riprova domani o alza il limite in Profilo."
            case .busy: "C'è già un'analisi in corso."
            }
        }
    }

    @Published var settings: Settings { didSet { persist() } }
    @Published private(set) var calls: [Call] = []
    private var inFlight = false
    private let defaults = UserDefaults.standard

    private init() {
        settings = (defaults.data(forKey: "ai.settings")).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        calls = (defaults.data(forKey: "ai.calls")).flatMap { try? JSONDecoder().decode([Call].self, from: $0) } ?? []
    }

    var monthCost: Double {
        let start = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
        return calls.filter { $0.date >= start }.reduce(0) { $0 + $1.costUSD }
    }

    var callsToday: Int {
        let start = Calendar.current.startOfDay(for: .now)
        return calls.filter { $0.date >= start }.count
    }

    /// Checks every limit and reserves the single request slot. Call `end` afterwards.
    /// `costly: false` for the free on-device model, which skips the money budget but keeps the other limits.
    func begin(costly: Bool = true) throws {
        guard settings.enabled else { throw Block.disabled }
        let budget = min(settings.monthlyBudgetUSD, Self.maxMonthlyBudgetCeiling)
        guard !costly || monthCost < budget else { throw Block.budget(budget) }
        let daily = min(settings.dailyMaxCalls, Self.maxDailyCallsCeiling)
        guard callsToday < daily else { throw Block.daily(daily) }
        guard !inFlight else { throw Block.busy }
        inFlight = true
    }

    /// Records one finished attempt (also failed ones, which may still have used tokens).
    /// `costUSD` overrides the Claude price estimate (0 for free engines).
    func record(inputTokens: Int, outputTokens: Int, outcome: String, costUSD: Double? = nil) {
        let cost = costUSD ?? (Double(inputTokens) * Self.inputPerMTok / 1_000_000 + Double(outputTokens) * Self.outputPerMTok / 1_000_000)
        let before = monthCost
        calls.append(Call(date: .now, inputTokens: inputTokens, outputTokens: outputTokens, costUSD: cost, outcome: outcome))
        calls = Array(calls.suffix(500))
        if let data = try? JSONEncoder().encode(calls) { defaults.set(data, forKey: "ai.calls") }
        DebugLog.shared.add("info", "ai", "\(outcome): \(inputTokens) in, \(outputTokens) out, \(cost.it(4)) $ · mese \(monthCost.it(2)) $")
        alertIfNeeded(before: before)
    }

    func end() { inFlight = false }

    /// One notification when the month crosses 80% of the budget.
    private func alertIfNeeded(before: Double) {
        let threshold = settings.monthlyBudgetUSD * 0.8
        guard before < threshold, monthCost >= threshold else { return }
        let content = UNMutableNotificationContent()
        content.title = "Budget AI all'80%"
        content.body = "Questo mese hai speso \(monthCost.it(2)) $ su \(settings.monthlyBudgetUSD.it(2)) $ per l'analisi delle foto."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ai.budget", content: content, trigger: nil))
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "ai.settings") }
    }

    /// Wait before retry `attempt` (1-based): the server's retry-after when given, else 2 s, 4 s… capped at 20 s.
    static func backoff(attempt: Int, retryAfter: String?) -> Double {
        if let header = retryAfter, let seconds = Double(header) { return min(seconds, 20) }
        return min(pow(2, Double(attempt)), 20)
    }
}
