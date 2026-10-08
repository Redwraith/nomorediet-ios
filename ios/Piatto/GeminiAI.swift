import Foundation
import UIKit

/// Meal analysis with Google Gemini (free tier of the Gemini API) using the user's own key from
/// Google AI Studio. Same prompt, review screen and limits as Claude; no money budget, since the free
/// tier is free — Google's quota applies instead.
enum GeminiAI {
    static let keyPage = URL(string: "https://aistudio.google.com/apikey")!
    static let base = "https://generativelanguage.googleapis.com/v1beta"
    private static let modelKey = "gemini.model"

    static var hasKey: Bool { Keychain.read(Keychain.gemini) != nil }
    /// Model picked when the key was checked (newest Flash model that can read images).
    static var model: String? { UserDefaults.standard.string(forKey: modelKey) }
    static var isReady: Bool { hasKey && model != nil }

    /// Checks the key and picks the model. Returns a message for the user.
    static func connect(key: String) async -> (ok: Bool, message: String) {
        var request = URLRequest(url: URL(string: "\(base)/models?pageSize=200")!)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return (false, "Nessuna connessione.") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            return (false, status == 400 || status == 403 ? "Chiave non valida: copiala di nuovo da AI Studio." : "Risposta inattesa (HTTP \(status)).")
        }
        let models = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["models"] as? [[String: Any]] ?? []
        guard let chosen = pickModel(models) else { return (false, "Nessun modello Gemini adatto disponibile per questa chiave.") }
        UserDefaults.standard.set(chosen, forKey: modelKey)
        return (true, "Chiave valida ✓ · \(chosen.replacingOccurrences(of: "models/", with: ""))")
    }

    /// Newest general "flash" model that supports generateContent; stable before preview.
    static func pickModel(_ models: [[String: Any]]) -> String? {
        let excluded = ["lite", "image", "tts", "live", "audio", "embedding", "exp", "learnlm", "robotics", "computer"]
        let candidates = models.compactMap { m -> String? in
            guard let name = m["name"] as? String, name.contains("gemini"), name.contains("flash"),
                  (m["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent"),
                  !excluded.contains(where: name.contains) else { return nil }
            return name
        }
        func version(_ name: String) -> Double {
            TextReader.numbers(in: name.replacingOccurrences(of: "models/gemini-", with: "")).first ?? 0
        }
        return candidates.sorted { a, b in
            if version(a) != version(b) { return version(a) > version(b) }
            let ap = a.contains("preview"), bp = b.contains("preview")
            if ap != bp { return !ap }
            return a.count < b.count
        }.first
    }

    /// Gemini step of `MealRecognizer`: recognises the foods in the photo and/or text and matches them to the catalog.
    @MainActor static func recognize(_ input: MealRecognizer.Input, catalog: String, corrections: [String])
        async throws -> (dish: String, items: [MealRecognizer.Raw], note: String) {
        guard let key = Keychain.read(Keychain.gemini), let model else { throw FoodAI.Failure.server("collega la chiave Gemini in Profilo → Analisi AI.") }
        var parts: [[String: Any]] = []
        if let image = input.image {
            guard let jpeg = image.resizedForClaude().jpegData(compressionQuality: 0.8) else { throw FoodAI.Failure.empty }
            parts.append(["inline_data": ["mime_type": "image/jpeg", "data": jpeg.base64EncodedString()]])
        }
        parts.append(["text": MealRecognizer.userText(input, corrections: corrections)])

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": MealRecognizer.system], ["text": "CATALOGO (nome | porzione standard):\n" + catalog]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": ["responseMimeType": "application/json", "responseSchema": MealRecognizer.schema(gemini: true),
                                 "maxOutputTokens": 8192],
        ]
        var request = URLRequest(url: URL(string: "\(base)/\(model):generateContent")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let guardian = AIGuard.shared
        try guardian.begin(costly: false)
        defer { guardian.end() }
        var json: [String: Any] = [:]
        var outcome = "errore"
        var tokensIn = 0, tokensOut = 0
        defer { guardian.record(inputTokens: tokensIn, outputTokens: tokensOut, outcome: "Gemini · " + outcome, costUSD: 0) }

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
                throw FoodAI.Failure.network(error.localizedDescription)
            }
            json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let usage = json["usageMetadata"] as? [String: Any] {
                tokensIn += usage["promptTokenCount"] as? Int ?? 0
                tokensOut += (usage["candidatesTokenCount"] as? Int ?? 0) + (usage["thoughtsTokenCount"] as? Int ?? 0)
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 200 { break }
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            DebugLog.shared.add("error", "ai", "Gemini tentativo \(attempt): HTTP \(status) \(message)")
            let retryable = status == 500 || status == 503 || status == 504
            if retryable && attempt < AIGuard.maxAttempts {
                try await Task.sleep(for: .seconds(AIGuard.backoff(attempt: attempt, retryAfter: http?.value(forHTTPHeaderField: "retry-after"))))
                continue
            }
            outcome = "HTTP \(status)"
            if status == 400 && message.lowercased().contains("api key") || status == 403 { throw FoodAI.Failure.server("chiave Gemini non valida: ricollegala in Profilo.") }
            if status == 429 { throw FoodAI.Failure.server("hai raggiunto il limite gratuito di Gemini: riprova più tardi o domani.") }
            if retryable { throw FoodAI.Failure.server("Gemini è sovraccarico, riprova tra poco.") }
            throw FoodAI.Failure.server(message)
        }

        if (json["promptFeedback"] as? [String: Any])?["blockReason"] != nil { outcome = "bloccata"; throw FoodAI.Failure.refused }
        let candidate = (json["candidates"] as? [[String: Any]])?.first ?? [:]
        if let reason = candidate["finishReason"] as? String, ["SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "RECITATION"].contains(reason) {
            outcome = "bloccata"; throw FoodAI.Failure.refused
        }
        let output = ((candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? [])
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }.joined()
        guard let parsed = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] else {
            outcome = "non leggibile"
            throw FoodAI.Failure.server("risposta di Gemini non leggibile, riprova.")
        }
        if parsed["contains_food"] as? Bool == false { outcome = "nessun cibo"; throw FoodAI.Failure.notFood(parsed["note"] as? String ?? "") }
        let result = MealRecognizer.parse(parsed)
        MealRecognizer.aiScaleGrams = (parsed["scale_grams"] as? NSNumber)?.doubleValue ?? 0
        guard !result.items.isEmpty else { outcome = "nessun cibo"; throw FoodAI.Failure.empty }
        outcome = "ok"
        return result
    }
}
