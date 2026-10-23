import Foundation
import UIKit

/// Meal analysis and coach with providers that speak the OpenAI chat-completions format, with the user's own key:
/// GLM by Z.ai (glm-4.7-flash for text and glm-4.6v-flash for photos are free) and DeepSeek (text only, very cheap,
/// pay-as-you-go). Same prompt, catalog grounding and review screen as Claude and Gemini.
enum OpenAICompatibleAI {
    struct Provider {
        let engine: AIGuard.Engine
        let name: String
        let base: String
        let keyService: String
        let keyPage: URL
        /// Tried in order: the first the account can use is kept.
        let textModels: [String]
        let visionModels: [String]
        let free: Bool
    }

    static let glm = Provider(engine: .glm, name: "GLM", base: "https://api.z.ai/api/paas/v4",
                              keyService: "app.piatto.ios.glm", keyPage: URL(string: "https://z.ai/manage-apikey/apikey-list")!,
                              textModels: ["glm-4.7-flash", "glm-4.5-flash"], visionModels: ["glm-4.6v-flash", "glm-4.1v-thinking-flash"],
                              free: true)
    static let deepseek = Provider(engine: .deepseek, name: "DeepSeek", base: "https://api.deepseek.com",
                                   keyService: "app.piatto.ios.deepseek", keyPage: URL(string: "https://platform.deepseek.com/api_keys")!,
                                   textModels: ["deepseek-chat"], visionModels: [], free: false)

    static func provider(_ engine: AIGuard.Engine) -> Provider? {
        switch engine {
        case .glm: glm
        case .deepseek: deepseek
        default: nil
        }
    }

    static func hasKey(_ p: Provider) -> Bool { Keychain.read(p.keyService) != nil }

    /// Recognises a key copied from the provider's page: GLM keys are "<id>.<secret>", DeepSeek's start with "sk-".
    static func looksLikeKey(_ text: String, for p: Provider) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(" "), t.count >= 20, t.count <= 200 else { return false }
        switch p.engine {
        case .glm: return t.contains(".") && !t.hasPrefix("sk-") && !t.hasPrefix("AIza")
        case .deepseek: return t.hasPrefix("sk-") && !t.hasPrefix("sk-ant-")
        default: return false
        }
    }

    /// Checks the key with a tiny request and remembers which model answered.
    static func connect(key: String, provider p: Provider) async -> (ok: Bool, message: String) {
        do {
            let (_, model) = try await complete(provider: p, key: key, models: p.textModels,
                                                messages: [["role": "user", "content": "Rispondi solo: ok"]], json: false, maxTokens: 8)
            Keychain.save(key, service: p.keyService)
            return (true, "\(p.name) collegato ✓ · \(model)")
        } catch {
            return (false, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// The step of `MealRecognizer` for these providers.
    @MainActor static func recognize(_ input: MealRecognizer.Input, catalog: String, corrections: [String], provider p: Provider)
        async throws -> (dish: String, items: [MealRecognizer.Raw], note: String) {
        guard let key = Keychain.read(p.keyService) else { throw FoodAI.Failure.server("collega \(p.name) in Profilo → Analisi AI.") }
        var models = p.textModels
        var content: Any = MealRecognizer.userText(input, corrections: corrections)
        if let image = input.image {
            guard !p.visionModels.isEmpty else {
                throw FoodAI.Failure.server("\(p.name) non legge le foto: scrivi o di' cosa hai mangiato, oppure scegli GLM o Gemini per le foto.")
            }
            guard let jpeg = image.resizedForClaude().jpegData(compressionQuality: 0.8) else { throw FoodAI.Failure.empty }
            models = p.visionModels
            content = [
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]],
                ["type": "text", "text": MealRecognizer.userText(input, corrections: corrections)],
            ]
        }
        let system = MealRecognizer.system + "\n\nCATALOGO (nome | porzione standard):\n" + catalog
            + "\n\nRispondi SOLO con un oggetto JSON valido, senza testo prima o dopo, con questa struttura (JSON Schema):\n"
            + schemaText(MealRecognizer.schema(gemini: false))
        let guardian = AIGuard.shared
        try guardian.begin(costly: !p.free)
        defer { guardian.end() }
        var outcome = "errore"
        defer { guardian.record(inputTokens: 0, outputTokens: 0, outcome: "\(p.name) · " + outcome, costUSD: 0) }
        let text: String
        do {
            (text, _) = try await complete(provider: p, key: key, models: models,
                                           messages: [["role": "system", "content": system], ["role": "user", "content": content]],
                                           json: true, maxTokens: 4096)
        } catch {
            outcome = "errore"
            throw error
        }
        guard let parsed = jsonObject(in: text) else { outcome = "non leggibile"; throw FoodAI.Failure.server("risposta di \(p.name) non leggibile, riprova.") }
        if parsed["contains_food"] as? Bool == false { outcome = "nessun cibo"; throw FoodAI.Failure.notFood(parsed["note"] as? String ?? "") }
        let result = MealRecognizer.parse(parsed)
        MealRecognizer.aiScaleGrams = (parsed["scale_grams"] as? NSNumber)?.doubleValue ?? 0
        guard !result.items.isEmpty else { outcome = "nessun cibo"; throw FoodAI.Failure.empty }
        outcome = "ok"
        return result
    }

    /// The coach with these providers: same system prompt and JSON reply as the other engines.
    @MainActor static func chat(system: String, schema: [String: Any], history: [(user: Bool, text: String)], text: String,
                                provider p: Provider) async throws -> [String: Any] {
        guard let key = Keychain.read(p.keyService) else { throw FoodAI.Failure.server("collega \(p.name) in Profilo → Analisi AI.") }
        var messages: [[String: Any]] = [["role": "system", "content": system + "\n\nRispondi SOLO con un oggetto JSON valido con questa struttura (JSON Schema):\n" + schemaText(schema)]]
        messages += history.map { ["role": $0.user ? "user" : "assistant", "content": $0.text] }
        messages.append(["role": "user", "content": text])
        let guardian = AIGuard.shared
        try guardian.begin(costly: !p.free)
        defer { guardian.end() }
        var outcome = "errore"
        defer { guardian.record(inputTokens: 0, outputTokens: 0, outcome: "\(p.name) coach · " + outcome, costUSD: 0) }
        let (reply, _) = try await complete(provider: p, key: key, models: p.textModels, messages: messages, json: true, maxTokens: 2048)
        guard let parsed = jsonObject(in: reply) else { outcome = "non leggibile"; throw FoodAI.Failure.server("risposta di \(p.name) non leggibile, riprova.") }
        outcome = "ok"
        return parsed
    }

    // MARK: Transport

    /// One chat completion; tries the next model when the account cannot use one, retries on overload.
    static func complete(provider p: Provider, key: String, models: [String], messages: [[String: Any]], json: Bool, maxTokens: Int)
        async throws -> (String, String) {
        var lastError: Error = FoodAI.Failure.server("\(p.name) non ha risposto.")
        for model in models {
            var body: [String: Any] = ["model": model, "messages": messages, "max_tokens": maxTokens, "temperature": 0.2, "stream": false]
            if json { body["response_format"] = ["type": "json_object"] }
            if p.engine == .glm { body["thinking"] = ["type": "disabled"] }
            var request = URLRequest(url: URL(string: p.base + "/chat/completions")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 90
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            for attempt in 1...AIGuard.maxAttempts {
                let data: Data, response: URLResponse
                do { (data, response) = try await URLSession.shared.data(for: request) } catch {
                    lastError = FoodAI.Failure.network(error.localizedDescription)
                    if attempt < AIGuard.maxAttempts { try await Task.sleep(for: .seconds(AIGuard.backoff(attempt: attempt, retryAfter: nil))); continue }
                    throw lastError
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                if status == 200 {
                    let message = ((object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) ?? [:]
                    let content = message["content"] as? String ?? ""
                    guard !content.isEmpty else { lastError = FoodAI.Failure.empty; break }
                    return (content, model)
                }
                let error = object["error"] as? [String: Any]
                let text = error?["message"] as? String ?? String(data: data, encoding: .utf8) ?? "HTTP \(status)"
                DebugLog.shared.add("error", "ai", "\(p.name) \(model) tentativo \(attempt): HTTP \(status) \(text.prefix(200))")
                switch status {
                case 401, 403: throw FoodAI.Failure.server("chiave \(p.name) non valida: ricollegala in Profilo → Analisi AI.")
                case 402: throw FoodAI.Failure.server("credito \(p.name) esaurito.")
                case 429 where attempt < AIGuard.maxAttempts, 500, 502, 503, 504:
                    if attempt < AIGuard.maxAttempts {
                        try await Task.sleep(for: .seconds(AIGuard.backoff(attempt: attempt, retryAfter: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after"))))
                        continue
                    }
                    throw FoodAI.Failure.server("\(p.name) è sovraccarico, riprova tra poco.")
                case 429: throw FoodAI.Failure.server("limite di \(p.name) raggiunto: riprova più tardi.")
                default:
                    // a model this account cannot use: try the next one
                    lastError = FoodAI.Failure.server(String(text.prefix(200)))
                }
                break
            }
        }
        throw lastError
    }

    /// The JSON object in a reply, also when wrapped in ```json fences or with text around it.
    static func jsonObject(in text: String) -> [String: Any]? {
        if let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] { return object }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any]
    }

    static func schemaText(_ schema: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
