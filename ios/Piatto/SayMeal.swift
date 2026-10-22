import SwiftData
import SwiftUI

/// "A colazione caffè e brioche, a pranzo pasta al pomodoro": the text split by the meals it names.
/// Words before any meal name go to the meal of the time of day.
enum MealSplitter {
    struct Part: Equatable {
        var slot: MealSlot?
        var text: String
    }

    private static let words: [(String, MealSlot)] = [
        ("colazione", .colazione), ("pranzo", .pranzo), ("pranzato", .pranzo), ("cena", .cena), ("cenato", .cena),
        ("spuntino", .spuntino), ("spuntini", .spuntino), ("merenda", .spuntino), ("snack", .spuntino),
    ]

    static func split(_ text: String) -> [Part] {
        let lower = text.lowercased()
        // every meal word as a whole word, in order of appearance
        var marks: [(range: Range<String.Index>, slot: MealSlot)] = []
        for (word, slot) in words {
            var from = lower.startIndex
            while let r = lower.range(of: word, range: from..<lower.endIndex) {
                let before = r.lowerBound == lower.startIndex ? nil : lower[lower.index(before: r.lowerBound)]
                let after = r.upperBound == lower.endIndex ? nil : lower[r.upperBound]
                if !(before?.isLetter ?? false) && !(after?.isLetter ?? false) { marks.append((r, slot)) }
                from = r.upperBound
            }
        }
        marks.sort { $0.range.lowerBound < $1.range.lowerBound }
        func clean(_ s: Substring) -> String {
            s.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-\n").union(.whitespaces))
        }
        var parts: [Part] = []
        let lead = clean(text[text.startIndex..<(marks.first?.range.lowerBound ?? text.endIndex)])
        // "stamattina a", "oggi ho mangiato a": words that only introduce the first meal name
        let fillers: Set<String> = ["a", "per", "al", "alla", "e", "poi", "ho", "mangiato", "bevuto", "preso", "oggi", "ieri",
                                    "stamattina", "stasera", "stamani", "mentre", "invece", "come", "di", "il", "la", "mi", "sono", "fatto"]
        let leadWords = lead.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if leadWords.contains(where: { !fillers.contains($0) }) { parts.append(Part(slot: nil, text: lead)) }
        for (i, mark) in marks.enumerated() {
            let end = i + 1 < marks.count ? marks[i + 1].range.lowerBound : text.endIndex
            var body = clean(text[mark.range.upperBound..<end])
            // drop a trailing "e a", "poi a" that introduces the next meal
            for tail in [" e a", " poi a", " e per", " a", " per", " e", " poi"] where body.lowercased().hasSuffix(tail) {
                body = clean(body.dropLast(tail.count)[...])
            }
            guard !body.isEmpty else { continue }
            if let last = parts.last, last.slot == mark.slot { parts[parts.count - 1].text += ", " + body }
            else { parts.append(Part(slot: mark.slot, text: body)) }
        }
        return parts
    }
}

/// The only way to log food on the Oggi screen: write or say what you ate, the chosen AI recognises the foods,
/// works out grams and nutrients and puts each one in its meal. One tap undoes it.
struct SayMealCard: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.modelContext) private var context
    @Query(sort: \CustomFood.createdAt, order: .reverse) private var customFoods: [CustomFood]
    @State private var text = ""
    @State private var listening = false
    @State private var working = false
    @State private var message: String?
    @State private var lastAdded: [FoodEntry] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cosa hai mangiato?").font(.headline)
            TextField("Es. a colazione caffè e 2 fette biscottate, a pranzo 80 g di pasta al pesto", text: $text, axis: .vertical)
                .lineLimit(2...6)
                .focused($focused)
                .padding(10)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("say-meal-text")
            HStack(spacing: 10) {
                Button {} label: {
                    Label(listening ? "Ti ascolto…" : "Tieni premuto e parla", systemImage: listening ? "waveform" : "mic.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(listening ? .red : Theme.accent)
                .simultaneousGesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !listening { startListening() } }
                    .onEnded { _ in stopListening() })
                .accessibilityIdentifier("say-meal-mic")
                Button { Task { await analyze() } } label: {
                    if working { ProgressView().frame(width: 44, height: 44) } else {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 40))
                    }
                }
                .disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
                .accessibilityLabel("Analizza e aggiungi")
                .accessibilityIdentifier("say-meal-send")
            }
            if working {
                Text(engineLabel + " sta capendo cosa hai mangiato…").font(.footnote).foregroundStyle(.secondary)
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !lastAdded.isEmpty {
                Button("Annulla l'ultimo inserimento", role: .destructive) { undo() }.font(.footnote)
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var engineLabel: String {
        guard FoodAI.isReady else { return "Nomorediet" }
        switch AIGuard.shared.settings.engine {
        case .apple: return "L'AI dell'iPhone"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        }
    }

    private func startListening() {
        listening = true
        focused = false
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        SpeechListener.shared.start { error in
            if let error { message = error; listening = false }
        }
    }

    private func stopListening() {
        guard listening else { return }
        listening = false
        SpeechListener.shared.stop { said in
            guard !said.isEmpty else { message = "Non ho sentito nulla, riprova."; return }
            text = text.isEmpty ? said : text + ", " + said
            Task { await analyze() }
        }
    }

    private func analyze() async {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard said.count >= 3, !working else { return }
        focused = false
        working = true
        message = nil
        defer { working = false }
        let foods = customFoods.map { Food(name: $0.name, per100: $0.per100, portion: $0.portion, portionName: "1 porzione", barcode: $0.barcode, source: .custom) }
            + FoodDatabase.foods
        let parts = MealSplitter.split(said)
        var added: [FoodEntry] = []
        var summary: [String] = []
        var problems: [String] = []
        for part in parts.isEmpty ? [MealSplitter.Part(slot: nil, text: said)] : parts {
            let slot = part.slot ?? MealSlot.now
            do {
                let result = try await MealRecognizer.recognize(MealRecognizer.Input(text: part.text), foods: foods)
                var kcal = 0.0
                for item in result.items where item.grams > 0 {
                    let entry = FoodEntry(day: app.day, slot: slot, name: item.name, grams: item.grams.rounded(), per100: item.per100)
                    context.insert(entry)
                    added.append(entry)
                    kcal += item.per100.kcal * item.grams / 100
                }
                summary.append("\(slot.title): \(result.items.map(\.name).joined(separator: ", ")) · \(kcal.it()) kcal")
            } catch {
                problems.append("\(slot.title): " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
                DebugLog.shared.add("error", "ai", "Pasto detto: \(error)")
            }
        }
        guard !added.isEmpty else {
            message = problems.first ?? "Non ho capito cosa hai mangiato: prova a scrivere alimenti e quantità."
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        lastAdded = added
        text = ""
        message = "Aggiunto ✓ " + summary.joined(separator: " — ") + (problems.isEmpty ? "" : "\nNon aggiunto: " + problems.joined(separator: "; "))
            + "\nTocca una voce per correggere i grammi."
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Sync.afterFoodChange(context: context, day: app.day)
        Hero.award(.food)
    }

    private func undo() {
        withAnimation { for entry in lastAdded { context.delete(entry) } }
        lastAdded = []
        message = "Inserimento annullato."
        Sync.afterFoodChange(context: context, day: app.day)
    }
}
