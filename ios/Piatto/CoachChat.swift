import AVFoundation
import SwiftData
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Chat with the coach, written or spoken. The coach knows today's goals, food and workout, answers in
/// Italian (aloud in voice mode) and records the sets you tell it: "panca 60 kg 4 serie da 8, mi sentivo bene".
/// Uses the engine chosen in Profile → Analisi AI; without one, it still records sets with an offline parser.
struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    var fromUser: Bool
    var text: String
    var date = Date()
    /// Sets understood from the user's message, waiting for "Salva" (nil when there are none).
    var pending: [ToldSets]? = nil
    /// "salvate" or "annullate" once the user has answered.
    var resolution: String? = nil
}

/// One exercise as told by the user.
struct ToldSets: Equatable, Codable {
    var exercise: String
    var kg: Double
    var sets: Int
    var reps: Int
    var rir: Int?
}

// MARK: - Store

@MainActor
final class CoachChat: ObservableObject {
    static let shared = CoachChat()
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var thinking = false
    @Published var speaks = UserDefaults.standard.object(forKey: "coach.voice") as? Bool ?? true {
        didSet { UserDefaults.standard.set(speaks, forKey: "coach.voice") }
    }
    private let speaker = AVSpeechSynthesizer()
    private static let key = "coach.chat.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            messages = saved
        }
    }

    func clear() {
        messages = []
        CoachAI.appleSession = nil
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Array(messages.suffix(60))) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// Sends the user's message, records any sets, appends and (in voice mode) speaks the coach's reply.
    func send(_ text: String, context: ModelContext, spoken: Bool) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !thinking else { return }
        messages.append(ChatMessage(fromUser: true, text: text))
        save()
        thinking = true
        defer { thinking = false }

        let situation = CoachContext.text(context: context)
        var reply: String
        var told: [ToldSets]
        do {
            (reply, told) = try await CoachAI.reply(to: text, history: Array(messages.dropLast().suffix(12)), situation: situation)
        } catch {
            told = WorkoutTextParser.parse(text)
            let why = (error as? LocalizedError)?.errorDescription ?? "AI non disponibile."
            reply = told.isEmpty
                ? "Non riesco a rispondere adesso (\(why)) Posso comunque registrare le serie se mi scrivi per esempio \"panca 60 kg 4x8\"."
                : "Registro le serie. (\(why))"
        }
        // never trust the model alone: a set is kept only if the user's own words contain it
        told = Self.validated(told, against: text)
        if told.isEmpty { told = WorkoutTextParser.parse(text) }
        messages.append(ChatMessage(fromUser: false, text: reply, pending: told.isEmpty ? nil : told))
        save()
        if spoken || speaks { CoachVoice.shared.speak(reply) }
    }

    /// The user confirmed (or rejected) the sets of a coach message.
    func resolve(_ id: UUID, save confirmed: Bool, context: ModelContext) {
        guard let i = messages.firstIndex(where: { $0.id == id }), let pending = messages[i].pending, messages[i].resolution == nil else { return }
        if confirmed {
            let saved = Self.record(pending, context: context)
            messages[i].resolution = saved.isEmpty ? "annullate" : "salvate"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            messages[i].resolution = "annullate"
        }
        save()
    }

    /// Keeps only sets that the message really describes: it must contain numbers, the set's numbers, and a word of
    /// the exercise. "Ciao come va" can never produce a set, whatever the model says.
    nonisolated static func validated(_ told: [ToldSets], against text: String) -> [ToldSets] {
        let normalized = FoodDatabase.normalize(text)
        let numbers = Set(TextReader.numbers(in: normalized.replacingOccurrences(of: ",", with: ".")).map { $0.rounded() })
        guard !numbers.isEmpty else { return [] }
        let words = normalized.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 3 }
        return told.filter { item in
            guard item.sets > 0, item.reps > 0, item.sets <= 12, item.reps <= 100, item.kg >= 0, item.kg <= 500 else { return false }
            let saysReps = numbers.contains(Double(item.reps)) || numbers.contains(Double(item.sets))
            let saysKg = item.kg == 0 || numbers.contains(item.kg.rounded())
            let nameWords = FoodDatabase.normalize(item.exercise).split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 3 }
            let saysExercise = nameWords.contains { n in words.contains { $0.hasPrefix(String(n.prefix(4))) || n.hasPrefix(String($0.prefix(4))) } }
            return saysReps && saysKg && saysExercise
        }
    }

    /// Saves the sets in the workout log, continuing today's numbering for each exercise.
    static func record(_ told: [ToldSets], context: ModelContext) -> [String] {
        let today = DayId.today
        var out: [String] = []
        for item in told where item.sets > 0 && item.reps > 0 {
            let name = ExerciseSwaps.match(item.exercise) ?? item.exercise.capitalized
            let existing = (try? context.fetch(FetchDescriptor<SetLog>(predicate: #Predicate { $0.day == today && $0.exercise == name })))?.count ?? 0
            for i in 0..<min(item.sets, 10) {
                context.insert(SetLog(day: today, exercise: name, index: existing + i + 1, reps: item.reps, kg: item.kg, rir: item.rir ?? 2))
            }
            out.append("\(name) \(item.kg > 0 ? "\(item.kg.it(1)) kg " : "")\(item.sets)×\(item.reps)")
        }
        if !out.isEmpty {
            let infos = (try? context.fetch(FetchDescriptor<DayInfo>(predicate: #Predicate { $0.day == today }))) ?? []
            if let info = infos.first { info.kind = .training } else { context.insert(DayInfo(day: today, kind: .training)) }
            Supplements.markTrained()
            Hero.award(.workout)
        }
        return out
    }

    func speak(_ text: String) { CoachVoice.shared.speak(text) }

    func stopSpeaking() { CoachVoice.shared.stop() }
}

// MARK: - What the coach knows

enum CoachContext {
    @MainActor static func text(context: ModelContext) -> String {
        let profile = ProfileStore.shared.profile
        let today = DayId.today
        let entries = (try? context.fetch(FetchDescriptor<FoodEntry>(predicate: #Predicate { $0.day == today }))) ?? []
        let sets = (try? context.fetch(FetchDescriptor<SetLog>(predicate: #Predicate { $0.day == today }))) ?? []
        let info = (try? context.fetch(FetchDescriptor<DayInfo>(predicate: #Predicate { $0.day == today })))?.first
        let kind = DayKind.of(today, saved: info?.kind, profile: profile)
        let goals = Nutrition.goals(profile, kind: kind)
        let totals = entries.reduce(Nutrients.zero) { $0 + $1.nutrients }
        var lines = [
            "Utente: \(profile.sex.rawValue), \(profile.age) anni, \(profile.heightCm.it()) cm, \(profile.weightKg.it(1)) kg, obiettivo \(profile.goal.title.lowercased()) (\(profile.targetKg.it()) kg), dieta \(profile.diet.title.lowercased())\(profile.vegetarian ? ", vegetariano" : "").",
            "Oggi è giorno di \(kind == .training ? "allenamento" : "riposo"). Obiettivo: \(goals.kcal.it()) kcal, P \(goals.protein.it()) g, C \(goals.carbs.it()) g, G \(goals.fat.it()) g.",
            "Mangiato finora: \(totals.kcal.it()) kcal, P \(totals.protein.it()) g, C \(totals.carbs.it()) g, G \(totals.fat.it()) g.",
            "Scheda: \(WorkoutPlan.name), \(Progression.title()).",
            "Integratori oggi: multivitaminico \(Supplements.isTaken(.multi) ? "preso" : "non ancora"), creatina \(Supplements.isTaken(.creatine) ? "presa" : "non ancora").",
        ]
        if !sets.isEmpty {
            let grouped = Dictionary(grouping: sets, by: \.exercise).map { name, s in
                "\(name): " + s.sorted { $0.index < $1.index }.map { "\($0.kg.it(1))×\($0.reps)" }.joined(separator: ", ")
            }
            lines.append("Serie registrate oggi: " + grouped.joined(separator: "; ") + ".")
        }
        let h = HealthCache.shared
        if let readiness = h.readiness { lines.append("Prontezza da Apple Salute: \(readiness)/100.") }
        var health: [String] = []
        if let v = h.steps { health.append("\(v.it()) passi oggi") }
        if let v = h.avgSteps { health.append("media \(v.it()) passi/giorno") }
        if let v = h.activeKcal { health.append("\(v.it()) kcal attive") }
        if let v = h.tdee { health.append("brucia in media \(v.it()) kcal/giorno") }
        if let v = h.sleepHours { health.append("dormito \(v.it(1)) h") }
        if let v = h.rhrToday { health.append("FC riposo \(v.it())") }
        if !h.workouts.isEmpty { health.append("allenamenti: " + h.workouts.map { "\($0.name) \($0.minutes.it()) min" }.joined(separator: ", ")) }
        if !health.isEmpty { lines.append("Apple Salute: " + health.joined(separator: ", ") + ".") }
        if profile.goal == .dimagrire {
            let plan = Nutrition.plan(profile)
            lines.append("Piano: da \(profile.weightKg.it(1)) a \(profile.targetKg.it(1)) kg, \(plan.daily.it()) kcal/giorno\(plan.date.map { ", traguardo \($0.formatted(.dateTime.day().month().year()))" } ?? "").")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Engines

enum CoachAI {
    static let system = """
    Sei il coach di Nomorediet: personal trainer e nutrizionista sportivo. Parli in italiano, in modo diretto, \
    motivante e concreto, come in una chat vocale: frasi brevi, niente elenchi lunghi, niente markdown, al massimo \
    5-6 frasi. Basati sui dati dell'utente qui sotto. Non dare diagnosi mediche.
    "sets" serve SOLO quando, nel suo ULTIMO messaggio, l'utente elenca esercizi fatti con i numeri (chili, serie, \
    ripetizioni): una voce per esercizio con nome, kg, numero di serie, ripetizioni (se diverse usa la media) e RIR se \
    lo dice (altrimenti -1). In quel caso commenta come è andata e dai un consiglio per la prossima volta. \
    In tutti gli altri casi (saluti, domande, dieta, messaggi senza numeri) "sets" è una lista VUOTA. \
    Non inventare mai esercizi o serie, e non ripetere serie dei messaggi precedenti.
    """

    /// The on-device conversation (LanguageModelSession), kept between messages.
    @MainActor static var appleSession: AnyObject?

    @MainActor static func reply(to text: String, history: [ChatMessage], situation: String) async throws -> (String, [ToldSets]) {
        let settings = AIGuard.shared.settings
        switch settings.engine {
        case .apple: return try await apple(text, situation: situation)
        case .claude: return try await claude(text, history: history, situation: situation)
        case .gemini: return try await gemini(text, history: history, situation: situation)
        case .glm, .deepseek, .groq:
            guard let provider = OpenAICompatibleAI.provider(settings.engine) else { throw FoodAI.Failure.server("motore non disponibile") }
            let parsed = try await OpenAICompatibleAI.chat(system: system + "\n\nDATI DI OGGI:\n" + situation, schema: schema(gemini: false),
                                                           history: history.map { (user: $0.fromUser, text: $0.text) }, text: text, provider: provider)
            return parse(parsed)
        }
    }

    // Apple on-device: one session keeps the conversation (small context, so it restarts when full).
    @MainActor private static func apple(_ text: String, situation: String) async throws -> (String, [ToldSets]) {
        #if canImport(FoundationModels)
        if #available(iOS 27, *) {
            guard OnDeviceAI.isAvailable else { throw FoodAI.Failure.server(OnDeviceAI.unavailableReason ?? "modello non disponibile") }
            let guardian = AIGuard.shared
            try guardian.begin(costly: false)
            defer { guardian.end() }
            var outcome = "errore"
            defer { guardian.record(inputTokens: 0, outputTokens: 0, outcome: "Apple coach · " + outcome, costUSD: 0) }
            let current = (appleSession as? LanguageModelSession) ?? LanguageModelSession(instructions: system + "\n\nDATI DI OGGI:\n" + situation)
            appleSession = current
            do {
                let response = try await current.respond(to: "Dati aggiornati: \(situation)\n\nUtente: \(text)", generating: CoachTurn.self)
                outcome = "ok"
                let sets = response.content.sets.map { ToldSets(exercise: $0.exercise, kg: $0.kg, sets: $0.sets, reps: $0.reps, rir: $0.rir >= 0 ? $0.rir : nil) }
                return (response.content.reply, sets)
            } catch {
                appleSession = nil
                outcome = "errore modello"
                DebugLog.shared.add("error", "coach", "Modello Apple: \(error)")
                throw FoodAI.Failure.server("il modello di Apple non ha risposto, riprova.")
            }
        }
        #endif
        throw FoodAI.Failure.server(OnDeviceAI.unavailableReason ?? "modello non disponibile")
    }

    static func schema(gemini: Bool) -> [String: Any] {
        func t(_ name: String) -> String { gemini ? name.uppercased() : name }
        var set: [String: Any] = [
            "type": t("object"),
            "properties": ["exercise": ["type": t("string")], "kg": ["type": t("number")], "sets": ["type": t("integer")],
                           "reps": ["type": t("integer")], "rir": ["type": t("integer")]],
            "required": ["exercise", "kg", "sets", "reps", "rir"],
        ]
        var root: [String: Any] = [
            "type": t("object"),
            "properties": ["reply": ["type": t("string")], "sets": ["type": t("array"), "items": set]],
            "required": ["reply", "sets"],
        ]
        if !gemini {
            set["additionalProperties"] = false
            root["properties"] = ["reply": ["type": "string"], "sets": ["type": "array", "items": set]]
            root["additionalProperties"] = false
        }
        return root
    }

    static func parse(_ json: [String: Any]) -> (String, [ToldSets]) {
        let sets = (json["sets"] as? [[String: Any]] ?? []).compactMap { row -> ToldSets? in
            guard let name = row["exercise"] as? String, !name.isEmpty else { return nil }
            let n = { (k: String) in (row[k] as? NSNumber)?.doubleValue ?? 0 }
            let rir = Int(n("rir"))
            return ToldSets(exercise: name, kg: n("kg"), sets: Int(n("sets")), reps: Int(n("reps")), rir: rir >= 0 ? rir : nil)
        }
        return (json["reply"] as? String ?? "", sets)
    }

    @MainActor private static func claude(_ text: String, history: [ChatMessage], situation: String) async throws -> (String, [ToldSets]) {
        guard let key = Keychain.read() else { throw FoodAI.Failure.noKey }
        var messages = history.map { ["role": $0.fromUser ? "user" : "assistant", "content": $0.text] }
        // the API needs the conversation to start with the user
        while messages.first?["role"] == "assistant" { messages.removeFirst() }
        messages.append(["role": "user", "content": text])
        let body: [String: Any] = [
            "model": FoodAI.model,
            "max_tokens": 4000,
            "fallbacks": "default",
            "system": [["type": "text", "text": system], ["type": "text", "text": "DATI DI OGGI:\n" + situation]],
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": schema(gemini: false)]],
            "messages": messages,
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let guardian = AIGuard.shared
        try guardian.begin()
        defer { guardian.end() }
        var outcome = "errore"
        var tokensIn = 0, tokensOut = 0
        defer { guardian.record(inputTokens: tokensIn, outputTokens: tokensOut, outcome: "Coach · " + outcome) }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: request) } catch {
            outcome = "rete"; throw FoodAI.Failure.network(error.localizedDescription)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let usage = json["usage"] as? [String: Any] {
            tokensIn = (usage["input_tokens"] as? Int ?? 0) + (usage["cache_read_input_tokens"] as? Int ?? 0)
            tokensOut = usage["output_tokens"] as? Int ?? 0
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            outcome = "HTTP \(status)"
            if status == 401 || status == 403 { throw FoodAI.Failure.badKey }
            throw FoodAI.Failure.server((json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)")
        }
        if json["stop_reason"] as? String == "refusal" { outcome = "rifiuto"; throw FoodAI.Failure.refused }
        let output = (json["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard let parsed = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] else {
            outcome = "non leggibile"; throw FoodAI.Failure.server("risposta non leggibile, riprova.")
        }
        outcome = "ok"
        return parse(parsed)
    }

    @MainActor private static func gemini(_ text: String, history: [ChatMessage], situation: String) async throws -> (String, [ToldSets]) {
        guard let key = Keychain.read(Keychain.gemini), let model = GeminiAI.model else { throw FoodAI.Failure.server("collega la chiave Gemini in Profilo → Analisi AI.") }
        var contents = history.map { ["role": $0.fromUser ? "user" : "model", "parts": [["text": $0.text]]] as [String: Any] }
        contents.append(["role": "user", "parts": [["text": text]]])
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": system], ["text": "DATI DI OGGI:\n" + situation]]],
            "contents": contents,
            "generationConfig": ["responseMimeType": "application/json", "responseSchema": schema(gemini: true), "maxOutputTokens": 4096],
        ]
        var request = URLRequest(url: URL(string: "\(GeminiAI.base)/\(model):generateContent")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let guardian = AIGuard.shared
        try guardian.begin(costly: false)
        defer { guardian.end() }
        var outcome = "errore"
        defer { guardian.record(inputTokens: 0, outputTokens: 0, outcome: "Gemini coach · " + outcome, costUSD: 0) }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: request) } catch {
            outcome = "rete"; throw FoodAI.Failure.network(error.localizedDescription)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            outcome = "HTTP \(status)"
            if status == 429 { throw FoodAI.Failure.server("limite gratuito di Gemini raggiunto, riprova più tardi.") }
            throw FoodAI.Failure.server((json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)")
        }
        let candidate = (json["candidates"] as? [[String: Any]])?.first ?? [:]
        let output = ((candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? [])
            .filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        guard let parsed = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] else {
            outcome = "non leggibile"; throw FoodAI.Failure.server("risposta di Gemini non leggibile, riprova.")
        }
        outcome = "ok"
        return parse(parsed)
    }
}

#if canImport(FoundationModels)
@available(iOS 27, *)
@Generable
struct CoachTurn {
    @Guide(description: "Risposta del coach in italiano, breve e parlata, massimo 5 frasi")
    var reply: String
    @Guide(description: "Vuoto, salvo che l'ultimo messaggio dell'utente elenchi esercizi fatti con chili, serie e ripetizioni. Mai inventare.")
    var sets: [CoachSet]
}

@available(iOS 27, *)
@Generable
struct CoachSet {
    @Guide(description: "Nome dell'esercizio in italiano")
    var exercise: String
    @Guide(description: "Chili usati, 0 se a corpo libero")
    var kg: Double
    @Guide(description: "Numero di serie")
    var sets: Int
    @Guide(description: "Ripetizioni per serie")
    var reps: Int
    @Guide(description: "Ripetizioni di riserva, -1 se non detto")
    var rir: Int
}
#endif

// MARK: - Offline parser

/// "panca 60 kg 4x8", "squat 80kg 3 serie da 10", "lat machine 50 chili 4 serie 12 ripetizioni".
enum WorkoutTextParser {
    static func parse(_ text: String) -> [ToldSets] {
        let normalized = FoodDatabase.normalize(text).replacingOccurrences(of: ",", with: ".")
        let chunks = normalized.components(separatedBy: CharacterSet(charactersIn: ";\n")).flatMap { $0.components(separatedBy: " poi ") }
            .flatMap { $0.components(separatedBy: ". ") }.flatMap { $0.components(separatedBy: " e ") }
        return chunks.compactMap(parseOne)
    }

    private static func parseOne(_ chunk: String) -> ToldSets? {
        func first(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: chunk, range: NSRange(chunk.startIndex..., in: chunk)) else { return nil }
            return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: chunk).map { String(chunk[$0]) } }
        }
        var sets = 0, reps = 0
        if let m = first("(\\d+)\\s*[x×]\\s*(\\d+)"), m.count == 2 { sets = Int(m[0]) ?? 0; reps = Int(m[1]) ?? 0 }
        if sets == 0, let m = first("(\\d+)\\s*serie"), let s = Int(m[0]) { sets = s }
        if reps == 0, let m = first("(?:da|di|x)\\s*(\\d+)\\s*(?:ripetizioni|rip|reps)?") ?? first("(\\d+)\\s*(?:ripetizioni|rip|reps)"), let r = Int(m[0]) { reps = r }
        guard sets > 0, reps > 0 else { return nil }
        let kg = first("(\\d+(?:\\.\\d+)?)\\s*(?:kg|chili|chilogrammi|kili)").flatMap { Double($0[0]) } ?? 0
        let rir = first("rir\\s*(\\d)").flatMap { Int($0[0]) }
        // the exercise name: the words before the first number
        let name = chunk.prefix { !$0.isNumber }.replacingOccurrences(of: "ho fatto", with: "").replacingOccurrences(of: "oggi", with: "")
            .trimmingCharacters(in: .whitespacesAndPunctuation)
        guard !name.isEmpty else { return nil }
        return ToldSets(exercise: name, kg: kg, sets: sets, reps: reps, rir: rir)
    }
}

private extension CharacterSet {
    static let whitespacesAndPunctuation = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
}

// MARK: - Screen

struct CoachChatView: View {
    @Environment(\.modelContext) private var context
    @ObservedObject private var chat = CoachChat.shared
    @ObservedObject private var voice = CoachVoice.shared
    @State private var draft = ""
    @State private var listening = false
    @State private var voiceError: String?
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if chat.messages.isEmpty { intro }
                        ForEach(chat.messages) { bubble($0).id($0.id) }
                        if chat.thinking {
                            HStack(spacing: 8) { ProgressView(); Text("Il coach sta scrivendo…").font(.caption).foregroundStyle(.secondary) }
                                .id("thinking")
                        }
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat.messages.count) { _, _ in withAnimation { proxy.scrollTo(chat.messages.last?.id, anchor: .bottom) } }
                .onChange(of: chat.thinking) { _, on in if on { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } } }
            }
            if let voiceError { Text(voiceError).font(.caption).foregroundStyle(.red).padding(.horizontal) }
            inputBar
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Chat con il coach")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: $chat.speaks) { Label("Risposte a voce", systemImage: "speaker.wave.2") }
                    Picker("Voce", selection: $voice.gender) {
                        Text("Voce di uomo").tag(CoachVoice.Gender.uomo)
                        Text("Voce di donna").tag(CoachVoice.Gender.donna)
                    }
                    Button { voice.speak(voice.gender == .uomo ? "Ciao, sono il tuo coach. Andiamo ad allenarci!" : "Ciao, sono la tua coach. Andiamo ad allenarci!") } label: {
                        Label("Prova la voce", systemImage: "play.circle")
                    }
                    Button(role: .destructive) { chat.clear() } label: { Label("Cancella la chat", systemImage: "trash") }
                } label: { Image(systemName: chat.speaks ? "speaker.wave.2.fill" : "speaker.slash") }
            }
        }
        .onDisappear { chat.stopSpeaking() }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ciao! Sono il tuo coach.").font(.headline)
            Text("Scrivimi o tieni premuto il microfono e parla. Puoi chiedermi cosa mangiare, come regolare i carichi, oppure raccontarmi l'allenamento: \"panca 60 kg 4 serie da 8, l'ultima faticosa\" e lo salvo io nella scheda.")
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(["Cosa mangio a cena per arrivare alle proteine?", "Oggi panca 60 kg 4x8 e lat machine 55 kg 3x10, mi sentivo carico", "Come sto andando questa settimana?"], id: \.self) { example in
                Button(example) { Task { await chat.send(example, context: context, spoken: false) } }
                    .font(.caption).buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private func bubble(_ m: ChatMessage) -> some View {
        HStack {
            if m.fromUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 10) {
                Text(m.text)
                    .textSelection(.enabled)
                if let pending = m.pending { setsCard(m, pending) }
            }
            .font(.body)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(m.fromUser ? Theme.accent : Theme.card, in: RoundedRectangle(cornerRadius: 18))
            .foregroundStyle(m.fromUser ? .white : .primary)
            .contextMenu { if !m.fromUser { Button("Ascolta") { chat.speak(m.text) } } }
            if !m.fromUser { Spacer(minLength: 40) }
        }
    }

    /// Sets understood from the message: saved only after "Salva".
    private func setsCard(_ m: ChatMessage, _ sets: [ToldSets]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(m.resolution == "salvate" ? "Salvato nella scheda" : m.resolution == "annullate" ? "Non salvato" : "Salvo queste serie?",
                  systemImage: m.resolution == "salvate" ? "checkmark.circle.fill" : "dumbbell.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(m.resolution == "annullate" ? .secondary : Theme.accent)
            ForEach(Array(sets.enumerated()), id: \.offset) { _, set in
                Text("• \(ExerciseSwaps.match(set.exercise) ?? set.exercise): \(set.kg > 0 ? "\(set.kg.it(1)) kg, " : "")\(set.sets) × \(set.reps)\(set.rir.map { " · RIR \($0)" } ?? "")")
                    .font(.subheadline)
            }
            if m.resolution == nil {
                HStack {
                    Button("Salva") { chat.resolve(m.id, save: true, context: context) }.buttonStyle(.borderedProminent)
                    Button("No") { chat.resolve(m.id, save: false, context: context) }.buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Scrivi al coach…", text: $draft, axis: .vertical)
                .accessibilityIdentifier("coach-text")
                .lineLimit(1...5)
                .focused($typing)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
            if draft.isEmpty {
                // hold to talk: the transcript is sent and the coach answers aloud
                Image(systemName: listening ? "waveform.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(listening ? .red : Theme.accent)
                    .symbolEffect(.pulse, isActive: listening)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in startListening() }
                        .onEnded { _ in stopListening() })
                    .accessibilityLabel("Tieni premuto e parla")
            } else {
                Button {
                    let text = draft
                    draft = ""
                    Task { await chat.send(text, context: context, spoken: false) }
                } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 38)) }
                .disabled(chat.thinking)
                .accessibilityLabel("Invia")
                .accessibilityIdentifier("coach-send")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private func startListening() {
        guard !listening else { return }
        listening = true
        voiceError = nil
        chat.stopSpeaking()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        SpeechListener.shared.start { error in
            if let error { voiceError = error; listening = false }
        }
    }

    private func stopListening() {
        guard listening else { return }
        listening = false
        SpeechListener.shared.stop { text in
            guard !text.isEmpty else { voiceError = "Non ho sentito niente: tieni premuto mentre parli."; return }
            Task { await chat.send(text, context: context, spoken: true) }
        }
    }
}
