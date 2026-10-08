import Charts
import SwiftData
import SwiftUI

/// Weight trend with forecast, weekly calories, adaptive maintenance and CSV export.
struct ProgressTab: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: ProfileStore
    @Environment(\.modelContext) private var context
    @Query(sort: \WeightEntry.day) private var weights: [WeightEntry]
    @Query private var entries: [FoodEntry]
    @Query private var dayInfos: [DayInfo]
    @State private var range = 30

    private var shownWeights: [WeightEntry] {
        let from = DayId.shift(DayId.today, by: -range)
        return weights.filter { $0.day >= from }
    }

    private var trend: (slope: Double, intercept: Double, origin: Date)? {
        let pts = weights.filter { $0.day >= DayId.shift(DayId.today, by: -28) }.map { (DayId.date($0.day), $0.kg) }
        return pts.count >= 3 ? Nutrition.trend(pts) : nil
    }

    struct DayKcal: Identifiable {
        var day: String
        var kcal: Double
        var goal: Double
        var id: String { day }
    }

    private var week: [DayKcal] {
        (0..<7).reversed().map { back in
            let day = DayId.shift(DayId.today, by: -back)
            let kcal = entries.filter { $0.day == day }.reduce(0) { $0 + $1.nutrients.kcal }
            let kind = DayKind.of(day, saved: dayInfos.first { $0.day == day }?.kind, profile: store.profile)
            return DayKcal(day: day, kcal: kcal, goal: Nutrition.goals(store.profile, kind: kind).kcal)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    HealthTodayCard()
                    weightCard
                    forecastCard
                    caloriesCard
                    StepsCard()
                    adaptiveCard
                    exportCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Progressi")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { app.sheet = .weight(.type) } label: { Label("Scrivi il peso", systemImage: "keyboard") }
                        Button { app.sheet = .weight(.voice) } label: { Label("Detta il peso", systemImage: "mic") }
                        Button { app.sheet = .weight(.scale) } label: { Label("Foto della bilancia", systemImage: "camera") }
                        Button { Sync.syncHealth(context: context) } label: { Label("Sincronizza Salute", systemImage: "heart") }
                    } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                }
            }
        }
    }

    private var weightCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Peso").font(.headline)
                Spacer()
                Picker("Periodo", selection: $range) {
                    Text("30 g").tag(30)
                    Text("90 g").tag(90)
                    Text("1 anno").tag(365)
                }
                .pickerStyle(.segmented).frame(width: 200)
            }
            if shownWeights.isEmpty {
                Text("Registra il peso per vedere l'andamento.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart {
                    ForEach(shownWeights) { w in
                        LineMark(x: .value("Giorno", DayId.date(w.day)), y: .value("kg", w.kg))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(Theme.accent)
                        PointMark(x: .value("Giorno", DayId.date(w.day)), y: .value("kg", w.kg))
                            .foregroundStyle(Theme.accent).symbolSize(20)
                    }
                    RuleMark(y: .value("Obiettivo", store.profile.targetKg))
                        .foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .leading) { Text("obiettivo \(store.profile.targetKg.it(1))").font(.caption2).foregroundStyle(.secondary) }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 200)
                if let last = shownWeights.last, let first = shownWeights.first, shownWeights.count > 1 {
                    let diff = last.kg - first.kg
                    Text("\(diff >= 0 ? "+" : "")\(diff.it(1)) kg nel periodo · ultimo \(last.kg.it(1)) kg")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private var forecastCard: some View {
        if let trend, let last = weights.last {
            let perWeek = trend.slope * 7
            let target = store.profile.targetKg
            let toGo = target - last.kg
            VStack(alignment: .leading, spacing: 8) {
                Label("Previsione", systemImage: "chart.line.uptrend.xyaxis").font(.headline)
                Text("Tendenza: \(perWeek >= 0 ? "+" : "")\(perWeek.it(2)) kg a settimana (ultime 4 settimane).")
                if abs(toGo) < 0.3 {
                    Text("Sei all'obiettivo. 🎯")
                } else if perWeek != 0 && (toGo / perWeek) > 0 {
                    let weeks = toGo / perWeek
                    let date = Calendar.current.date(byAdding: .day, value: Int(weeks * 7), to: .now) ?? .now
                    Text("A questo ritmo arrivi a \(target.it(1)) kg verso il \(date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "it_IT")))).")
                        .fontWeight(.semibold)
                } else {
                    Text("Con la tendenza attuale non ti stai avvicinando a \(target.it(1)) kg.")
                }
                if abs(perWeek) > last.kg * 0.01 {
                    Text("Stai cambiando più dell'1% del peso a settimana: un ritmo più lento aiuta a mantenere i muscoli.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private var caloriesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calorie della settimana").font(.headline)
            Chart {
                ForEach(week) { d in
                    BarMark(x: .value("Giorno", DayId.date(d.day), unit: .day), y: .value("kcal", d.kcal))
                        .foregroundStyle(d.kcal > d.goal * 1.05 ? Color.orange.gradient : Theme.accent.gradient)
                        .cornerRadius(6)
                    LineMark(x: .value("Giorno", DayId.date(d.day), unit: .day), y: .value("Obiettivo", d.goal))
                        .foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow).locale(Locale(identifier: "it_IT")))
                }
            }
            .frame(height: 180)
            let logged = week.filter { $0.kcal > 0 }
            if !logged.isEmpty {
                let avg = logged.reduce(0) { $0 + $1.kcal } / Double(logged.count)
                Text("Media \(avg.it()) kcal nei \(logged.count) giorni registrati").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var adaptiveCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Calorie adattive", systemImage: "gauge.with.dots.needle.67percent").font(.headline)
            if let tdee = store.profile.adaptiveTDEE {
                Text("Dal cibo registrato e dall'andamento del peso, il tuo mantenimento reale è circa **\(tdee.it()) kcal**. Gli obiettivi giornalieri usano questo valore.")
            } else {
                Text("Registra cibo per almeno 10 giorni e il peso per 2 settimane: poi calcolo il tuo mantenimento reale e adatto le calorie da solo. Per ora uso la formula: \(Nutrition.maintenance(store.profile).it()) kcal.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Esporta").font(.headline)
            Text("Riepilogo giorno per giorno degli ultimi 30 giorni: calorie, macro, fibre e peso.").font(.subheadline).foregroundStyle(.secondary)
            ShareLink(item: CSVExport.file(entries: entries, weights: weights, days: 30),
                      preview: SharePreview("Nomorediet – ultimi 30 giorni")) {
                Label("Esporta CSV", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }
}

enum CSVExport {
    static func file(entries: [FoodEntry], weights: [WeightEntry], days: Int) -> URL {
        var rows = ["data;kcal;proteine_g;carboidrati_g;grassi_g;fibre_g;peso_kg"]
        for back in (0..<days).reversed() {
            let day = DayId.shift(DayId.today, by: -back)
            let n = entries.filter { $0.day == day }.reduce(Nutrients.zero) { $0 + $1.nutrients }
            let kg = weights.first { $0.day == day }?.kg
            guard n.kcal > 0 || kg != nil else { continue }
            rows.append([day, n.kcal.it(), n.protein.it(1), n.carbs.it(1), n.fat.it(1), n.fiber.it(1), kg.map { $0.it(1) } ?? ""]
                .joined(separator: ";"))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nomorediet-\(DayId.today).csv")
        try? ("\u{FEFF}" + rows.joined(separator: "\r\n")).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Weight by typing, by voice, or by a photo of the scale display.
struct WeightSheet: View {
    enum Mode: String { case type, voice, scale }
    @State var mode: Mode
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppState
    @State private var text = ""
    @State private var listening = false
    @State private var status: String?
    @State private var showCamera = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("85,4", text: $text).keyboardType(.decimalPad).font(.system(size: 44, weight: .bold, design: .rounded))
                        Text("kg").font(.title).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button {
                    } label: {
                        Label(listening ? "Sto ascoltando… rilascia per finire" : "Tieni premuto e di' il peso", systemImage: listening ? "waveform" : "mic.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .simultaneousGesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !listening { startListening() } }
                        .onEnded { _ in stopListening() })
                    Button { showCamera = true } label: { Label("Foto del display della bilancia", systemImage: "camera") }
                }
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Peso di \(DayId.label(app.day).lowercased())")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        if let kg = text.italianDouble, kg >= 30, kg <= 300 {
                            Sync.saveWeight((kg * 10).rounded() / 10, day: app.day, source: mode.rawValue, context: context)
                            dismiss()
                        } else { status = "Scrivi un peso tra 30 e 300 kg." }
                    }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    showCamera = false
                    guard let image else { return }
                    status = "Leggo il display…"
                    Task {
                        let lines = await TextReader.lines(in: image)
                        if let kg = TextReader.scaleWeight(lines) {
                            text = kg.it(1)
                            mode = .scale
                            status = "Ho letto \(kg.it(1)) kg: controlla e premi Salva."
                        } else {
                            status = "Non riesco a leggere il numero: avvicinati al display e riprova, o scrivilo."
                        }
                    }
                }
                .ignoresSafeArea()
            }
            .onAppear {
                if mode == .scale { showCamera = true }
                if mode == .voice { status = "Tieni premuto il pulsante del microfono e di' per esempio \"ottantacinque e quattro\"." }
            }
        }
    }

    private func startListening() {
        listening = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        SpeechListener.shared.start { error in
            if let error { status = error; listening = false }
        }
    }

    private func stopListening() {
        guard listening else { return }
        listening = false
        SpeechListener.shared.stop { said in
            if let kg = SpokenNumber.kilograms(said) {
                text = kg.it(1)
                mode = .voice
                status = "Ho sentito \"\(said)\" → \(kg.it(1)) kg."
            } else {
                status = said.isEmpty ? "Non ho sentito nulla, riprova." : "Ho sentito \"\(said)\" ma non trovo un peso."
            }
        }
    }
}

/// "85,4", "85 virgola 4", "ottantacinque e quattro", "ottantacinque chili e mezzo".
enum SpokenNumber {
    private static let units = ["zero": 0, "uno": 1, "un": 1, "due": 2, "tre": 3, "quattro": 4, "cinque": 5, "sei": 6, "sette": 7,
                                "otto": 8, "nove": 9, "dieci": 10, "undici": 11, "dodici": 12, "tredici": 13, "quattordici": 14,
                                "quindici": 15, "sedici": 16, "diciassette": 17, "diciotto": 18, "diciannove": 19]
    private static let tens = ["venti": 20, "trenta": 30, "quaranta": 40, "cinquanta": 50, "sessanta": 60, "settanta": 70,
                               "ottanta": 80, "novanta": 90, "cento": 100]

    static func kilograms(_ text: String) -> Double? {
        let t = FoodDatabase.normalize(text)
        let digits = TextReader.numbers(in: t)
        if let first = digits.first {
            if first >= 30 && first <= 300 {
                if t.contains("mezzo") { return first + 0.5 }
                if digits.count > 1, first == first.rounded(), digits[1] < 10 { return first + digits[1] / 10 }
                return first
            }
        }
        let parts = t.replacingOccurrences(of: "virgola", with: " e ").components(separatedBy: " e ")
        guard let whole = word(parts[0]), whole >= 30 else { return nil }
        if t.contains("mezzo") { return Double(whole) + 0.5 }
        if parts.count > 1, let dec = word(parts[1]) ?? Int(parts[1].trimmingCharacters(in: .whitespaces)), dec < 10 {
            return Double(whole) + Double(dec) / 10
        }
        return Double(whole)
    }

    /// One number written in Italian words, up to 299.
    private static func word(_ raw: String) -> Int? {
        var s = raw.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "chili", with: "")
            .replacingOccurrences(of: "chilo", with: "").replacingOccurrences(of: "kg", with: "")
        if let n = Int(s) { return n }
        var total = 0
        if s.hasPrefix("duecento") { total += 200; s.removeFirst(8) } else if s.hasPrefix("cento") { total += 100; s.removeFirst(5) }
        for (w, v) in tens.sorted(by: { $0.key.count > $1.key.count }) where w != "cento" {
            // "ottantuno", "ottantotto": tens drop the last vowel before uno/otto
            let stem = String(w.dropLast())
            if s.hasPrefix(w) { total += v; s.removeFirst(w.count); break }
            if s.hasPrefix(stem), let rest = units[String(s.dropFirst(stem.count))], rest == 1 || rest == 8 { total += v; s.removeFirst(stem.count); break }
        }
        if !s.isEmpty {
            guard let u = units[s] else { return total > 0 ? total : nil }
            total += u
        }
        return total > 0 ? total : nil
    }
}

/// Steps per day from Apple Health (directly or through the Shortcuts automation).
struct StepsCard: View {
    @ObservedObject private var health = HealthCache.shared
    @State private var range = 7
    static let goal = 8000.0

    struct DaySteps: Identifiable {
        var day: String
        var steps: Double
        var id: String { day }
    }

    private var days: [DaySteps] {
        (0..<range).reversed().map { back in
            let day = DayId.shift(DayId.today, by: -back)
            return DaySteps(day: day, steps: health.dailySteps[day] ?? 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Passi").font(.headline)
                Spacer()
                Picker("Periodo", selection: $range) {
                    Text("7 g").tag(7)
                    Text("30 g").tag(30)
                }
                .pickerStyle(.segmented).frame(width: 120)
            }
            if health.dailySteps.isEmpty {
                Text("Collega Apple Salute (Profilo → Apple Salute) per vedere i passi di ogni giorno.")
                    .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100)
            } else {
                Chart {
                    ForEach(days) { d in
                        BarMark(x: .value("Giorno", DayId.date(d.day), unit: .day), y: .value("Passi", d.steps))
                            .foregroundStyle(d.steps >= Self.goal ? Theme.accent.gradient : Color.blue.opacity(0.6).gradient)
                            .cornerRadius(range == 7 ? 6 : 2)
                    }
                    RuleMark(y: .value("Obiettivo", Self.goal))
                        .foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("\(Self.goal.it()) passi").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: range == 7 ? 1 : 7)) { _ in
                        AxisValueLabel(format: (range == 7 ? Date.FormatStyle().weekday(.narrow) : Date.FormatStyle().day().month(.abbreviated))
                            .locale(Locale(identifier: "it_IT")))
                    }
                }
                .frame(height: 180)
                let counted = days.filter { $0.steps > 0 }
                if !counted.isEmpty {
                    let avg = counted.reduce(0) { $0 + $1.steps } / Double(counted.count)
                    let reached = counted.filter { $0.steps >= Self.goal }.count
                    Text("Media \(avg.it()) passi al giorno · \(reached) giorni su \(counted.count) sopra \(Self.goal.it())")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }
}
