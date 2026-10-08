import SwiftData
import SwiftUI

/// Rule-based coach: today's advice from the logged data, readiness from Apple Health,
/// hero level, reminders and the weekly recap.
struct CoachTab: View {
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var app: AppState
    @ObservedObject private var health = HealthCache.shared
    @Environment(\.modelContext) private var context
    @Query private var entries: [FoodEntry]
    @Query private var weights: [WeightEntry]
    @Query private var dayInfos: [DayInfo]
    @Query private var sets: [SetLog]

    private var todayEntries: [FoodEntry] { entries.filter { $0.day == DayId.today } }
    private var totals: Nutrients { todayEntries.reduce(.zero) { $0 + $1.nutrients } }
    private var kind: DayKind { DayKind.of(DayId.today, saved: dayInfos.first { $0.day == DayId.today }?.kind, profile: store.profile) }
    private var goals: Goals { Nutrition.goals(store.profile, kind: kind) }

    /// Consecutive days with food logged, up to today.
    private var streak: Int {
        let days = Set(entries.map(\.day))
        var count = 0, day = DayId.today
        if !days.contains(day) { day = DayId.shift(day, by: -1) }
        while days.contains(day) { count += 1; day = DayId.shift(day, by: -1) }
        return count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    heroCard
                    NavigationLink { CoachChatView() } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "bubble.left.and.text.bubble.right.fill").font(.title2).foregroundStyle(.white)
                                .frame(width: 48, height: 48).background(Theme.accent, in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Parla con il coach").font(.headline)
                                Text("Chat scritta o vocale · raccontagli l'allenamento e lo salva").font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "mic.fill").foregroundStyle(Theme.accent)
                        }
                        .padding(14)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    if let score = health.readiness { readinessCard(score) }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Consigli di oggi").font(.headline)
                        ForEach(tips, id: \.text) { tip in
                            Label { Text(tip.text) } icon: { Image(systemName: tip.icon).foregroundStyle(tip.color) }
                                .font(.subheadline)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
                    weeklyCard
                    remindersCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Coach")
            .refreshable { Sync.syncHealth(context: context) }
        }
    }

    private var heroCard: some View {
        let progress = Double(Hero.xp) / Double(max(Hero.nextLevelXP, 1))
        return HStack(spacing: 16) {
            ZStack {
                Ring(progress: progress, color: .purple, width: 8)
                MovementFigure(pattern: "push_v", size: 56)
            }
            .frame(width: 78, height: 78)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Hero.title) · livello \(Hero.level)").font(.headline)
                Text("\(Hero.xp) / \(Hero.nextLevelXP) punti").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                Text(streak > 0 ? "🔥 \(streak) giorni di fila con il diario" : "Registra un pasto per iniziare la serie").font(.subheadline)
            }
            Spacer()
        }
        .padding(14)
        .background(LinearGradient(colors: [.purple.opacity(0.18), Theme.card], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 18))
    }

    private func readinessCard(_ score: Int) -> some View {
        let color: Color = score >= 70 ? .green : score >= 45 ? .orange : .red
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Prontezza").font(.headline)
                Spacer()
                Text("\(score)").font(.title.bold().monospacedDigit()).foregroundStyle(color)
            }
            Text(score >= 70 ? "Sei recuperato: buona giornata per spingere sui carichi."
                 : score >= 45 ? "Recupero nella media: allenati, ma tieni 2 ripetizioni di riserva."
                 : "Recupero basso: fai la seduta più leggera o sposta l'allenamento a domani.")
                .font(.subheadline)
            HStack(spacing: 16) {
                if let s = health.sleepHours { Label("\(s.it(1)) h sonno", systemImage: "bed.double") }
                if let h = health.hrvToday { Label("HRV \(h.it())", systemImage: "waveform.path.ecg") }
                if let r = health.rhrToday { Label("FC \(r.it())", systemImage: "heart") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    struct Tip { var icon: String; var color: Color; var text: String }

    private var tips: [Tip] {
        var out: [Tip] = []
        let hour = Calendar.current.component(.hour, from: .now)
        let proteinLeft = goals.protein - totals.protein
        if todayEntries.isEmpty {
            out.append(Tip(icon: "sunrise.fill", color: .orange, text: "Non hai ancora registrato nulla oggi: inizia dalla colazione, bastano pochi secondi con Ripeti."))
        }
        if proteinLeft > 25 && hour >= 15 {
            out.append(Tip(icon: "bolt.heart.fill", color: .pink,
                           text: "Ti mancano \(proteinLeft.it()) g di proteine: yogurt greco o skyr (17 g a vasetto), tofu (20 g a panetto) o una porzione di legumi."))
        }
        if totals.kcal > goals.kcal * 1.05 {
            out.append(Tip(icon: "exclamationmark.triangle.fill", color: .orange,
                           text: "Sei sopra l'obiettivo di \((totals.kcal - goals.kcal).it()) kcal. Niente drammi: conta la media della settimana."))
        } else if hour >= 20 && totals.kcal < goals.kcal * 0.7 && !todayEntries.isEmpty {
            out.append(Tip(icon: "fork.knife", color: .blue,
                           text: "Sei molto sotto l'obiettivo. Mangiare troppo poco fa perdere muscolo: aggiungi qualcosa di proteico."))
        }
        if store.profile.vegetarian && hour >= 17 && totals.iron < goals.iron * 0.6 {
            out.append(Tip(icon: "drop.fill", color: .red,
                           text: "Ferro basso oggi: lenticchie, ceci, spinaci o semi di zucca, con un agrume per assorbirlo meglio. Evita tè e caffè vicino ai pasti."))
        }
        if hour >= 17 && totals.fiber < goals.fiber * 0.5 {
            out.append(Tip(icon: "leaf.fill", color: .green, text: "Poche fibre: aggiungi verdura, frutta o legumi a cena."))
        }
        if kind == .training && !sets.contains(where: { $0.day == DayId.today }) {
            out.append(Tip(icon: "dumbbell.fill", color: Theme.accent, text: "Oggi è giorno di allenamento: hai più carboidrati a disposizione, mangiane una parte 1–2 ore prima."))
        }
        if !weights.contains(where: { $0.day == DayId.today }) && hour < 12 {
            out.append(Tip(icon: "scalemass.fill", color: .blue, text: "Pesati ora, a digiuno e dopo il bagno: è il momento più affidabile."))
        }
        if let steps = health.steps, steps < 6000, hour >= 16 {
            out.append(Tip(icon: "figure.walk", color: .teal, text: "\(steps.it()) passi finora: una camminata di 20 minuti ne aggiunge circa 2.500."))
        }
        if out.isEmpty {
            out.append(Tip(icon: "checkmark.seal.fill", color: .green, text: "Tutto in linea con gli obiettivi di oggi. Continua così."))
        }
        return out
    }

    private var weeklyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Riepilogo settimanale").font(.headline)
            Text(WeeklyRecap.text(entries: entries, weights: weights, sets: sets, profile: store.profile))
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(6)
            ShareLink(item: WeeklyRecap.text(entries: entries, weights: weights, sets: sets, profile: store.profile),
                      subject: Text("Nomorediet · la mia settimana")) {
                Label("Condividi o invia per email", systemImage: "envelope")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var remindersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $store.profile.reminders) { Text("Promemoria").font(.headline) }
                .onChange(of: store.profile.reminders) { _, _ in applyReminders() }
            if store.profile.reminders {
                ForEach(["colazione", "pranzo", "cena", "checkin"], id: \.self) { slot in
                    DatePicker(slot == "checkin" ? "Check-in serale" : slot.capitalized,
                               selection: timeBinding(slot), displayedComponents: .hourAndMinute)
                }
                Text("Il promemoria di un pasto non arriva se l'hai già registrato.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            SupplementSettings()
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private func timeBinding(_ slot: String) -> Binding<Date> {
        Binding(
            get: {
                let parts = (store.profile.reminderTimes[slot] ?? "12:00").split(separator: ":").compactMap { Int($0) }
                return Calendar.current.date(bySettingHour: parts.first ?? 12, minute: parts.last ?? 0, second: 0, of: .now) ?? .now
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                store.profile.reminderTimes[slot] = String(format: "%02d:%02d", c.hour ?? 12, c.minute ?? 0)
                applyReminders()
            })
    }

    private func applyReminders() {
        Reminders.configure(times: store.profile.reminderTimes, enabled: store.profile.reminders)
    }
}

enum WeeklyRecap {
    static func text(entries: [FoodEntry], weights: [WeightEntry], sets: [SetLog], profile: Profile) -> String {
        let days = (0..<7).map { DayId.shift(DayId.today, by: -$0) }
        let logged = days.compactMap { day -> Nutrients? in
            let n = entries.filter { $0.day == day }.reduce(Nutrients.zero) { $0 + $1.nutrients }
            return n.kcal > 0 ? n : nil
        }
        var lines = ["Nomorediet · settimana fino a \(DayId.label(DayId.today).lowercased())"]
        if logged.isEmpty {
            lines.append("Nessun pasto registrato negli ultimi 7 giorni.")
        } else {
            let avg = logged.reduce(Nutrients.zero, +).scaled(1 / Double(logged.count))
            let goal = Nutrition.goals(profile, kind: .rest)
            lines.append("Diario: \(logged.count)/7 giorni registrati.")
            lines.append("Media: \(avg.kcal.it()) kcal (obiettivo ~\(goal.kcal.it())), proteine \(avg.protein.it()) g, fibre \(avg.fiber.it()) g.")
        }
        let w = weights.filter { days.contains($0.day) }.sorted { $0.day < $1.day }
        if let first = w.first, let last = w.last, w.count > 1 {
            let d = last.kg - first.kg
            lines.append("Peso: \(first.kg.it(1)) → \(last.kg.it(1)) kg (\(d >= 0 ? "+" : "")\(d.it(1))).")
        } else if let last = w.last {
            lines.append("Peso: \(last.kg.it(1)) kg.")
        }
        let trained = Set(sets.filter { days.contains($0.day) }.map(\.day)).count
        lines.append("Allenamenti: \(trained) di \(profile.trainingDays) previsti, \(sets.filter { days.contains($0.day) }.count) serie.")
        return lines.joined(separator: "\n")
    }
}
