import Foundation

/// What the AI is asked to do. Each kind of request has its own best engine.
enum AITask: String, CaseIterable {
    /// A photo of a meal or of a pack.
    case photo
    /// A typed or spoken meal.
    case text
    /// The chat with the coach.
    case coach

    var title: String {
        switch self {
        case .photo: "Foto"
        case .text: "Testo e voce"
        case .coach: "Coach"
        }
    }
}

/// Chooses, for each task, the best engine among the ready ones and moves on to the next when one fails
/// (overloaded, out of quota, offline), so a request is not lost because one provider is busy.
@MainActor
enum AIRouter {
    /// Best first. Only free engines: Claude and DeepSeek cost money, so they are used only when chosen by hand
    /// (Profilo → Analisi AI with "Scelta automatica" off) and nothing is spent unasked.
    /// - photo: Gemini Flash reads images best; then Groq (Llama 4 Scout), GLM, and the iPhone's own model.
    /// - text and coach: Groq answers in a couple of seconds; then Gemini, GLM and the iPhone.
    static func preference(for task: AITask) -> [AIGuard.Engine] {
        switch task {
        case .photo: [.gemini, .groq, .glm, .apple]
        case .text, .coach: [.groq, .gemini, .glm, .apple]
        }
    }

    /// The engine has a key (or, for Apple, the model on the iPhone) and can be used right now.
    static func isReady(_ engine: AIGuard.Engine) -> Bool {
        switch engine {
        case .apple: OnDeviceAI.isAvailable
        case .claude: FoodAI.hasKey
        case .gemini: GeminiAI.isReady
        case .glm: OpenAICompatibleAI.hasKey(OpenAICompatibleAI.glm)
        case .deepseek: OpenAICompatibleAI.hasKey(OpenAICompatibleAI.deepseek)
        case .groq: OpenAICompatibleAI.hasKey(OpenAICompatibleAI.groq)
        }
    }

    /// The engines to try for this task, in order: with "Scelta automatica" the ready free engines by preference,
    /// otherwise only the one chosen in Profilo.
    static func engines(for task: AITask) -> [AIGuard.Engine] {
        let settings = AIGuard.shared.settings
        guard settings.auto else { return isReady(settings.engine) ? [settings.engine] : [] }
        return preference(for: task).filter(isReady)
    }

    static func name(_ engine: AIGuard.Engine) -> String {
        switch engine {
        case .apple: "L'AI dell'iPhone"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .glm: "GLM"
        case .deepseek: "DeepSeek"
        case .groq: "Groq"
        }
    }

    /// Runs `attempt` with the best engine for the task and, if it fails for a reason another engine may not have,
    /// with the next one. An answer that is simply "no food here", the kill switch, the budget or the daily limit
    /// are not retried.
    static func run<T>(_ task: AITask, _ attempt: (AIGuard.Engine) async throws -> T) async throws -> T {
        let chain = engines(for: task)
        guard !chain.isEmpty else { throw FoodAI.Failure.server("scegli e attiva un motore in Profilo → Analisi AI.") }
        var lastError: Error = FoodAI.Failure.server("nessun motore ha risposto.")
        for (index, engine) in chain.enumerated() {
            do {
                return try await attempt(engine)
            } catch {
                lastError = error
                guard index < chain.count - 1, shouldTryNext(after: error) else { throw error }
                DebugLog.shared.add("warn", "ai", "\(task.title): \(name(engine)) non ha risposto, provo \(name(chain[index + 1]))")
            }
        }
        throw lastError
    }

    static func shouldTryNext(after error: Error) -> Bool {
        if error is CancellationError || error is AIGuard.Block { return false }
        if case FoodAI.Failure.notFood = error { return false }
        return true
    }

    /// Which engine does what right now, for Profilo.
    static func summary() -> String {
        AITask.allCases.map { task in
            let names = engines(for: task).map(name)
            return "\(task.title): " + (names.isEmpty ? "nessun motore collegato" : names.joined(separator: " → "))
        }.joined(separator: "\n")
    }
}
