import Charts
import SwiftUI

/// "Quanto vuoi dimagrire?": target weight and speed → daily calories and the date you get there.
/// Maintenance comes from Apple Health (steps, resting and active energy) or the diary when available.
struct WeightPlanView: View {
    @EnvironmentObject private var store: ProfileStore
    @ObservedObject private var health = HealthCache.shared
    private let speeds: [(Double, String, String)] = [
        (0.25, "Lento", "facile da mantenere"),
        (0.5, "Consigliato", "il miglior equilibrio"),
        (0.75, "Veloce", "serve più disciplina"),
        (1.0, "Molto veloce", "solo per poche settimane"),
    ]

    var body: some View {
        let p = store.profile
        let plan = Nutrition.plan(p)
        Form {
            Section {
                Stepper("Peso di oggi: \(p.weightKg.it(1)) kg", value: $store.profile.weightKg, in: 35...250, step: 0.5)
                Stepper("Voglio arrivare a: \(p.targetKg.it(1)) kg", value: $store.profile.targetKg, in: 35...250, step: 0.5)
                if plan.kgToLose > 0 {
                    Text("Da perdere: \(plan.kgToLose.it(1)) kg").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                } else {
                    Text("Il peso obiettivo è uguale o sopra quello di oggi.").font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("Obiettivo") }

            Section {
                Picker("Velocità", selection: $store.profile.lossPerWeek) {
                    ForEach(speeds, id: \.0) { speed in
                        Text("\(speed.1) · \(speed.0.it(2)) kg/sett.").tag(speed.0)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: { Text("Quanto velocemente") } footer: {
                Text(speeds.first { $0.0 == p.lossPerWeek }?.2.capitalized ?? "")
            }

            Section {
                row("Bruci in media", "\(plan.maintenance.it()) kcal al giorno")
                row("Mangia", "\(plan.daily.it()) kcal al giorno")
                row("Deficit", "−\(plan.deficit.it()) kcal al giorno")
                if let date = plan.date, let weeks = plan.weeks {
                    row("Arrivi a \(p.targetKg.it(1)) kg", "\(date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "it_IT")))) · \(weeks) settimane")
                }
                if plan.limited {
                    Label("Non scendo sotto \(Nutrition.floor(p).it()) kcal: sotto questa soglia perderesti muscolo. Per questo il ritmo è più lento di quello scelto.",
                          systemImage: "exclamationmark.shield").font(.footnote).foregroundStyle(.orange)
                }
                Text(sourceText(p)).font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Il tuo piano") } footer: {
                Text("Nei giorni di allenamento mangi un po' di più e in quelli di riposo un po' meno: la media è questa. Il piano si aggiorna da solo con i tuoi passi e con l'andamento del peso.")
            }

            if let weeks = plan.weeks, plan.kgToLose > 0 {
                Section("Come scenderà il peso") {
                    Chart {
                        ForEach(0...weeks, id: \.self) { week in
                            LineMark(x: .value("Settimana", week), y: .value("kg", max(p.targetKg, p.weightKg - plan.weekly * Double(week))))
                                .foregroundStyle(Theme.accent)
                                .interpolationMethod(.monotone)
                        }
                        RuleMark(y: .value("Obiettivo", p.targetKg))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .annotation(position: .top, alignment: .trailing) { Text("\(p.targetKg.it()) kg").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .chartXAxisLabel("settimane")
                    .chartYScale(domain: (p.targetKg - 1)...(p.weightKg + 1))
                    .frame(height: 180)
                    ForEach(checkpoints(plan, p), id: \.0) { label, kg in
                        row(label, "\(kg.it(1)) kg")
                    }
                }
            }

            if health.avgSteps != nil || health.tdee != nil {
                Section("Da Apple Salute (media 14 giorni)") {
                    if let s = health.avgSteps { row("Passi", "\(s.it()) al giorno") }
                    if let a = health.avgActiveKcal { row("Calorie attive", "\(a.it()) kcal") }
                    if let t = health.tdee { row("Calorie totali bruciate", "\(t.it()) kcal") }
                }
            }
        }
        .navigationTitle("Piano per dimagrire")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if store.profile.goal != .dimagrire { store.profile.goal = .dimagrire } }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).multilineTextAlignment(.trailing) }
    }

    private func checkpoints(_ plan: Nutrition.Plan, _ p: Profile) -> [(String, Double)] {
        guard let weeks = plan.weeks else { return [] }
        return [4, 8, 12, 16, 24].filter { $0 < weeks }.map { w in
            ("Tra \(w) settimane", max(p.targetKg, p.weightKg - plan.weekly * Double(w)))
        }
    }

    private func sourceText(_ p: Profile) -> String {
        switch Nutrition.maintenanceSource(p) {
        case .adaptive: "Calcolato da quello che mangi e da come cambia il tuo peso: è la stima più precisa."
        case .health: "Calcolato da Apple Salute: calorie a riposo + calorie attive misurate da iPhone e Apple Watch."
        case .steps: "Stimato da età, altezza, peso e dai tuoi \(p.avgSteps?.it() ?? "") passi al giorno in Apple Salute."
        case .formula: "Stimato da età, altezza, peso e livello di attività. Attiva Apple Salute in Profilo per usare i tuoi passi."
        }
    }
}

/// Today in Apple Health (iPhone + Apple Watch): activity, energy, heart and workouts.
struct HealthTodayCard: View {
    @ObservedObject private var health = HealthCache.shared
    @Environment(\.modelContext) private var context

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Oggi da Apple Salute", systemImage: "heart.text.square.fill").font(.headline).foregroundStyle(.pink)
                Spacer()
                if let updated = health.updated { Text(updated.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                Button { Sync.syncHealth(context: context) } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Sincronizza Salute")
            }
            if health.updated == nil {
                Text("Collega Apple Salute in Profilo → Apple Salute: con SideStore i dati arrivano dal comando rapido \"\(ShortcutHealth.shortcutName)\" (passi, calorie, peso, battito, HRV, sonno, VO₂ max, grasso).")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                    tile("Passi", health.steps.map { $0.it() }, "figure.walk", .green)
                    tile("Km", health.km.map { $0.it(1) }, "map", .teal)
                    tile("Kcal attive", health.activeKcal.map { $0.it() }, "flame.fill", .orange)
                    tile("Kcal a riposo", health.basalKcal.map { $0.it() }, "bed.double.fill", .indigo)
                    tile("Esercizio", health.exerciseMin.map { "\($0.it()) min" }, "figure.run", .green)
                    tile("Piani", health.flights.map { $0.it() }, "figure.stairs", .brown)
                    tile("Battito medio", health.heartRateAvg.map { "\($0.it()) bpm" }, "heart.fill", .red)
                    tile("FC a riposo", health.rhrToday.map { "\($0.it()) bpm" }, "heart", .pink)
                    tile("HRV", health.hrvToday.map { "\($0.it()) ms" }, "waveform.path.ecg", .purple)
                    tile("Sonno", health.sleepHours.map { "\($0.it(1)) h" }, "moon.zzz.fill", .blue)
                    tile("VO₂ max", health.vo2max.map { $0.it(1) }, "lungs.fill", .cyan)
                    tile("Grasso", health.bodyFat.map { "\($0.it(1))%" }, "percent", .gray)
                }
                if !health.workouts.isEmpty {
                    Divider()
                    ForEach(Array(health.workouts.enumerated()), id: \.offset) { _, w in
                        Label("\(w.name): \(w.minutes.it()) min\(w.kcal > 0 ? " · \(w.kcal.it()) kcal" : "")", systemImage: "figure.strengthtraining.traditional")
                            .font(.subheadline)
                    }
                }
                if let steps = health.avgSteps {
                    Text("Media ultimi 14 giorni: \(steps.it()) passi\(health.tdee.map { " · \($0.it()) kcal bruciate al giorno" } ?? "").")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private func tile(_ title: String, _ value: String?, _ icon: String, _ color: Color) -> some View {
        if let value {
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: icon).foregroundStyle(color).font(.caption)
                Text(value).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
