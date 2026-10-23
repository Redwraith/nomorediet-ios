import Foundation
import Security
import UIKit

/// Shared types for meal analysis, and the Claude engine (Anthropic Messages API with the user's own key).
/// The photo or text goes straight from the iPhone to Anthropic; nothing else leaves the device.
enum FoodAI {
    struct Item: Identifiable, Hashable {
        let id = UUID()
        var name: String
        var grams: Double
        var per100: Nutrients
        var confidence: String
        /// Nutrients come from Nomorediet's food table (true) or from the model's estimate (false).
        var fromTable = false
        /// What the AI recognised, when the table name differs ("Pasta al pomodoro").
        var detail = ""
    }

    struct Result {
        var dish: String
        var items: [Item]
        var note: String
    }

    enum Failure: LocalizedError {
        case noKey, badKey, refused, empty, notFood(String), server(String), network(String)
        var errorDescription: String? {
            switch self {
            case .noKey: "Inserisci la chiave API Anthropic in Profilo → Analisi AI, oppure scegli il modello di Apple."
            case .badKey: "La chiave API non è valida o è stata revocata: controllala in Profilo → Analisi AI."
            case .refused: "L'AI non ha analizzato questo pasto. Prova con un'altra foto o descrizione, o aggiungi gli alimenti a mano."
            case .notFood(let what): "Nella foto non vedo cibo\(what.isEmpty ? "" : ": sembra \(what)"). Non ho aggiunto niente. Fotografa il piatto dall'alto, oppure tocca \"È cibo, analizza comunque\"."
            case .empty: "Non ho trovato alimenti. Inquadra il piatto dall'alto con buona luce, o descrivi meglio cosa hai mangiato."
            case .server(let m): "Analisi non riuscita: \(m)"
            case .network(let m): "Connessione non riuscita: \(m)"
            }
        }
    }

    static var hasKey: Bool { Keychain.read() != nil }

    /// The engine chosen in Profile is ready to analyse photos.
    @MainActor static var isReady: Bool {
        switch AIGuard.shared.settings.engine {
        case .apple: OnDeviceAI.isAvailable
        case .claude: hasKey
        case .gemini: GeminiAI.isReady
        case .glm: OpenAICompatibleAI.hasKey(OpenAICompatibleAI.glm)
        case .deepseek: OpenAICompatibleAI.hasKey(OpenAICompatibleAI.deepseek)
        }
    }

    static let model = "claude-opus-5-5"

    /// Claude step of `MealRecognizer`: recognises the foods in the photo and/or text and matches them to the catalog.
    @MainActor static func recognize(_ input: MealRecognizer.Input, catalog: String, corrections: [String])
        async throws -> (dish: String, items: [MealRecognizer.Raw], note: String) {
        guard let key = Keychain.read() else { throw Failure.noKey }
        var content: [[String: Any]] = []
        if let image = input.image {
            guard let jpeg = image.resizedForClaude().jpegData(compressionQuality: 0.8) else { throw Failure.empty }
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]])
        }
        content.append(["type": "text", "text": MealRecognizer.userText(input, corrections: corrections)])

        // System prompt and catalog are stable, so they are cached between photos.
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8000,
            "fallbacks": "default",
            "cache_control": ["type": "ephemeral"],
            "system": [
                ["type": "text", "text": MealRecognizer.system],
                ["type": "text", "text": "CATALOGO (nome | porzione standard):\n" + catalog],
            ],
            "output_config": [
                "effort": "medium",
                "format": ["type": "json_schema", "schema": MealRecognizer.schema(gemini: false)],
            ],
            "messages": [["role": "user", "content": content]],
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Every limit is checked before spending anything; at most `AIGuard.maxAttempts` tries, with backoff.
        let guardian = AIGuard.shared
        try guardian.begin()
        defer { guardian.end() }
        var json: [String: Any] = [:]
        var outcome = "errore"
        var tokensIn = 0, tokensOut = 0
        defer { guardian.record(inputTokens: tokensIn, outputTokens: tokensOut, outcome: outcome) }

        for attempt in 1...AIGuard.maxAttempts {
            let data: Data, response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                if attempt < AIGuard.maxAttempts {
                    try await Task.sleep(for: .seconds(AIGuard.backoff(attempt: attempt, retryAfter: nil)))
                    continue
                }
                outcome = "rete"
                throw Failure.network(error.localizedDescription)
            }
            json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let usage = json["usage"] as? [String: Any] {
                tokensIn += (usage["input_tokens"] as? Int ?? 0) + (usage["cache_read_input_tokens"] as? Int ?? 0)
                tokensOut += usage["output_tokens"] as? Int ?? 0
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 200 { break }
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            DebugLog.shared.add("error", "ai", "Tentativo \(attempt): HTTP \(status) \(message)")
            let retryable = status == 429 || status == 529 || status >= 500
            if retryable && attempt < AIGuard.maxAttempts {
                try await Task.sleep(for: .seconds(AIGuard.backoff(attempt: attempt, retryAfter: http?.value(forHTTPHeaderField: "retry-after"))))
                continue
            }
            outcome = "HTTP \(status)"
            if status == 401 || status == 403 { throw Failure.badKey }
            if status == 429 { throw Failure.server("troppe richieste, riprova tra un minuto.") }
            if retryable { throw Failure.server("servizio sovraccarico, riprova tra poco.") }
            throw Failure.server(message)
        }
        if json["stop_reason"] as? String == "refusal" { outcome = "rifiuto"; throw Failure.refused }
        if json["stop_reason"] as? String == "max_tokens" { outcome = "troncata"; throw Failure.server("risposta troppo lunga, riprova.") }

        let output = (json["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard let parsed = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] else {
            DebugLog.shared.add("error", "ai", "Risposta non leggibile (\(json["stop_reason"] as? String ?? "?"))")
            outcome = "non leggibile"
            throw Failure.server("risposta non leggibile, riprova.")
        }

        if parsed["contains_food"] as? Bool == false { outcome = "nessun cibo"; throw Failure.notFood(parsed["note"] as? String ?? "") }
        let result = MealRecognizer.parse(parsed)
        MealRecognizer.aiScaleGrams = (parsed["scale_grams"] as? NSNumber)?.doubleValue ?? 0
        guard !result.items.isEmpty else { outcome = "nessun cibo"; throw Failure.empty }
        outcome = "ok"
        return result
    }

    /// Checks the key with a tiny request.
    static func test(key: String) async -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models/\(model)")!)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return "Nessuna connessione." }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return "Chiave valida ✓"
        case 401, 403: return "Chiave non valida."
        case let code: return "Risposta inattesa (HTTP \(code))."
        }
    }

    /// Corrections the user made to AI estimates, used as hints next time.
    enum Corrections {
        private static let key = "ai.corrections"
        static var all: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        static func add(name: String, estimated: Double, actual: Double) {
            guard abs(estimated - actual) >= max(10, estimated * 0.15) else { return }
            let line = "\(name): stimati \(Int(estimated)) g, erano \(Int(actual)) g"
            UserDefaults.standard.set(Array((all + [line]).suffix(30)), forKey: key)
        }
    }
}

/// API keys, kept in the Keychain (one per provider). Saved in iCloud Keychain when available, so a reinstall
/// or a new iPhone finds them again; on the iPhone only otherwise.
enum Keychain {
    static let anthropic = "app.piatto.ios.anthropic"
    static let gemini = "app.piatto.ios.gemini"

    static func read(_ service: String = anthropic) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func save(_ key: String, service: String = anthropic) {
        delete(service)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let synced: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                     kSecAttrSynchronizable as String: true,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                                     kSecValueData as String: Data(trimmed.utf8)]
        if SecItemAdd(synced as CFDictionary, nil) == errSecSuccess { return }
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                   kSecValueData as String: Data(trimmed.utf8)]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(_ service: String = anthropic) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrSynchronizable as String: kSecAttrSynchronizableAny] as CFDictionary)
    }
}

extension UIImage {
    /// Claude works best with images up to about 1568 px on the long side; larger ones only cost more.
    func resizedForClaude(maxSide: CGFloat = 1568) -> UIImage {
        let longSide = max(size.width, size.height)
        guard longSide > maxSide else { return self }
        let scale = maxSide / longSide
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}
