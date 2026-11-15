import Foundation

/// Jev, TypeSafe's System One model: fast typed judgments instead of generated text. Tempra uses it where a
/// decision is needed, not a text: which product of the food database is the food the user ate (choosing among
/// real Open Food Facts / USDA / table entries instead of trusting the model's own numbers), and which meal a
/// food belongs to. With the user's own key, kept in the Keychain; without it the app works as before.
enum JevAI {
    static let keyService = "app.piatto.ios.typesafe"
    static let keyPage = URL(string: "https://typesafe.ai")!
    private static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let model = "jev-latest"

    static var isReady: Bool { Keychain.read(keyService) != nil }

    // MARK: Wire format (POST /v1/systemone)

    /// A Choice question: one of `criteria` (name → when it applies).
    struct Choice {
        var instructions: String
        var criteria: [(String, String)]
    }

    struct Answer: Equatable {
        var choice: String
        var confidence: Double
        var probabilities: [String: Double]
        func probability(_ name: String) -> Double { probabilities[name] ?? (choice == name ? confidence : 0) }
    }

    enum Failure: LocalizedError {
        case noKey, refused(String), network(String), unreadable
        var errorDescription: String? {
            switch self {
            case .noKey: "collega Jev in Profilo → Analisi AI."
            case .refused(let m): "Jev: \(m)"
            case .network(let m): "Jev non raggiungibile: \(m)"
            case .unreadable: "risposta di Jev non leggibile."
            }
        }
    }

    static func body(state: Any, questions: [String: Choice]) -> [String: Any] {
        var q: [String: Any] = [:]
        for (id, choice) in questions {
            var criteria: [String: Any] = [:]
            for (name, meaning) in choice.criteria { criteria[name] = meaning }
            q[id] = ["type": "choice", "instructions": choice.instructions, "criteria": criteria]
        }
        return ["model": model, "state": state, "questions": q]
    }

    static func parse(_ data: Data) -> [String: Answer]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let answers = object["answers"] as? [String: Any] else { return nil }
        var out: [String: Answer] = [:]
        for (id, value) in answers {
            guard let a = value as? [String: Any], let choice = a["choice"] as? String else { continue }
            let probabilities = (a["probabilities"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
            out[id] = Answer(choice: choice, confidence: (a["confidence"] as? NSNumber)?.doubleValue ?? 0, probabilities: probabilities)
        }
        return out
    }

    /// Several independent questions about the same state, answered together in one request.
    static func ask(state: Any, questions: [String: Choice], key: String? = nil, timeout: TimeInterval = 8) async throws -> [String: Answer] {
        guard let key = key ?? Keychain.read(keyService) else { throw Failure.noKey }
        guard !questions.isEmpty else { return [:] }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(state: state, questions: questions))
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch { throw Failure.network(error.localizedDescription) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let text = String(data: data, encoding: .utf8)?.prefix(160) ?? ""
            DebugLog.shared.add("error", "ai", "Jev HTTP \(status) \(text)")
            switch status {
            case 401, 403: throw Failure.refused("chiave non valida, ricollegala in Profilo → Analisi AI.")
            case 402: throw Failure.refused("credito esaurito.")
            case 429: throw Failure.refused("troppe richieste, riprova tra poco.")
            default: throw Failure.refused("errore \(status).")
            }
        }
        guard let answers = parse(data) else { throw Failure.unreadable }
        return answers
    }

    /// Checks the key with one tiny question and saves it.
    static func connect(key: String) async -> (ok: Bool, message: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await ask(state: "pasta al pomodoro",
                              questions: ["test": Choice(instructions: "È un cibo?", criteria: [("si", "È un cibo o una bevanda"), ("no", "Non è un cibo")])],
                              key: key)
            Keychain.save(key, service: keyService)
            return (true, "Jev collegato ✓")
        } catch {
            return (false, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

/// Picks, for each recognised food, the database entry that really is what was eaten: candidates come from the
/// app's table, the large weekly database (Open Food Facts Italy + USDA) and, when those have little, Open Food
/// Facts online; Jev chooses among them or says none fits. Nutrients then come from the chosen entry.
enum FoodChooser {
    static let none = "nessuno"
    /// Below this the first matching (code's fuzzy match) stays.
    static let threshold = 0.5

    struct Pick {
        var food: Food?
        var probability: Double
    }

    /// Candidates for one food, best first, without duplicates.
    static func candidates(for raw: MealRecognizer.Raw, in foods: [Food], online: [Food] = [], limit: Int = 9) -> [Food] {
        let words = FoodDatabase.normalize(raw.name).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 }
        let local = FoodStore.rank(foods.filter { food in
            let n = FoodDatabase.normalize(food.name)
            return words.contains(where: n.contains)
        }, words: words)
        var all = Array(local.prefix(4))
        if FoodStore.shared.isAvailable {
            all += FoodStore.shared.search(raw.name, limit: 5)
            if !raw.nameEn.isEmpty, raw.nameEn.lowercased() != raw.name.lowercased() { all += FoodStore.shared.search(raw.nameEn, limit: 3) }
        }
        all += online.prefix(4)
        var seen = Set<String>()
        return Array(all.filter { $0.per100.kcal > 0 && seen.insert(FoodDatabase.normalize($0.name) + "|" + ($0.brand ?? "")).inserted }.prefix(limit))
    }

    static func label(_ food: Food) -> String {
        let n = food.per100
        var parts = [food.name]
        if let brand = food.brand, !brand.isEmpty { parts.append("marca \(brand)") }
        parts.append("per 100 g: \(Int(n.kcal)) kcal, proteine \(n.protein.it(1)) g, carboidrati \(n.carbs.it(1)) g, grassi \(n.fat.it(1)) g")
        return parts.joined(separator: " · ")
    }

    static func question(for raw: MealRecognizer.Raw, index: Int, candidates: [Food]) -> JevAI.Choice {
        var criteria = candidates.enumerated().map { ("c\($0.offset)", label($0.element)) }
        criteria.append((none, "Nessuna voce corrisponde davvero all'alimento: è un altro cibo, un altro taglio o una preparazione diversa (per esempio crudo invece che cotto, intero invece che scremato)."))
        return JevAI.Choice(
            instructions: "Quale voce del database è l'alimento `alimenti[\(index)]` che l'utente ha mangiato? Considera nome, stato (crudo o cotto), preparazione e marca se indicata, e se i valori per 100 g sono plausibili per quel cibo. Una voce generica va bene se non è indicata una marca.",
            criteria: criteria)
    }

    /// Asks Jev about every food at once. Returns one pick per raw item (nil food = keep what code found).
    static func choose(_ raws: [MealRecognizer.Raw], said: String, foods: [Food]) async -> [Pick?] {
        guard JevAI.isReady, !raws.isEmpty else { return raws.map { _ in nil } }
        var lists: [[Food]] = []
        for raw in raws {
            var list = candidates(for: raw, in: foods)
            if list.count < 3, raw.name.count >= 3 {
                let online = (try? await withTimeout(4) { try await OpenFoodFacts.search(raw.name) }) ?? []
                list = candidates(for: raw, in: foods, online: online)
            }
            lists.append(list)
        }
        let state: [String: Any] = [
            "descrizione_utente": String(said.prefix(600)),
            "alimenti": raws.map { ["nome": $0.name, "descrizione": $0.description, "grammi": Int($0.grams)] as [String: Any] },
        ]
        var questions: [String: JevAI.Choice] = [:]
        for (i, raw) in raws.enumerated() where !lists[i].isEmpty {
            questions["food\(i)"] = question(for: raw, index: i, candidates: lists[i])
        }
        guard !questions.isEmpty else { return raws.map { _ in nil } }
        let start = Date()
        do {
            let answers = try await JevAI.ask(state: state, questions: questions)
            DebugLog.shared.add("info", "ai", "Jev: \(questions.count) alimenti in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            return raws.indices.map { i in
                guard let answer = answers["food\(i)"] else { return nil }
                return pick(answer, candidates: lists[i])
            }
        } catch {
            DebugLog.shared.add("error", "ai", "Jev: \(error.localizedDescription)")
            return raws.map { _ in nil }
        }
    }

    /// Turns an answer into a pick: a candidate when Jev is sure enough, "none" when it is sure nothing fits.
    static func pick(_ answer: JevAI.Answer, candidates: [Food]) -> Pick? {
        if answer.choice == none { return answer.confidence >= threshold ? Pick(food: nil, probability: answer.confidence) : nil }
        guard answer.choice.hasPrefix("c"), let i = Int(answer.choice.dropFirst()), candidates.indices.contains(i),
              answer.probability(answer.choice) >= threshold else { return nil }
        return Pick(food: candidates[i], probability: answer.probability(answer.choice))
    }

    private static func withTimeout<T>(_ seconds: Double, _ work: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); throw CancellationError() }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}

/// The meal a food belongs to when the text does not say it: "un caffè e una brioche" at 10 is breakfast,
/// "un gelato" at 16 a snack. Jev judges from the food and the time; without Jev, the time of day decides.
enum MealSlotChooser {
    static func choose(_ texts: [String], at date: Date = .now) async -> [MealSlot?] {
        guard JevAI.isReady, !texts.isEmpty else { return texts.map { _ in nil } }
        let hour = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
        let state: [String: Any] = ["ora_attuale": hour, "fascia_oraria_predefinita": MealSlot.at(date).rawValue, "cibi": texts]
        let criteria = [
            (MealSlot.colazione.rawValue, "Colazione: il primo pasto della giornata, di solito al mattino (caffè, latte, biscotti, cornetto, yogurt, cereali)."),
            (MealSlot.pranzo.rawValue, "Pranzo: il pasto principale di metà giornata (primi, secondi, piatti unici, panino come pasto)."),
            (MealSlot.spuntino.rawValue, "Spuntino o merenda: piccola quantità tra i pasti o dopo cena (frutta, snack, gelato, barretta, frullato)."),
            (MealSlot.cena.rawValue, "Cena: il pasto principale della sera."),
        ]
        var questions: [String: JevAI.Choice] = [:]
        for i in texts.indices {
            questions["slot\(i)"] = JevAI.Choice(
                instructions: "In quale pasto della giornata va registrato quello che l'utente ha mangiato in `cibi[\(i)]`, considerando il tipo di cibo, la quantità e l'ora attuale? Se cibo e ora non bastano a deciderlo, scegli la fascia oraria predefinita.",
                criteria: criteria)
        }
        guard let answers = try? await JevAI.ask(state: state, questions: questions, timeout: 5) else { return texts.map { _ in nil } }
        return texts.indices.map { i in
            guard let a = answers["slot\(i)"], a.confidence >= 0.5 else { return nil }
            return MealSlot(rawValue: a.choice)
        }
    }
}
