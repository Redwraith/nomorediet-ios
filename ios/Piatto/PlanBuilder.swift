import SwiftUI

/// Muscle groups the plan builder offers, by movement pattern.
enum MuscleGroup {
    static let all: [(pattern: String, title: String, short: String)] = [
        ("push_h", "Petto · spinte", "Petto"), ("fly", "Petto · croci", "Petto"),
        ("pull_v", "Dorso · tirate dall'alto", "Dorso"), ("pull_h", "Dorso · row", "Dorso"), ("pullover", "Dorso · pullover", "Dorso"),
        ("push_v", "Spalle · spinte", "Spalle"), ("raise_l", "Spalle · alzate laterali", "Spalle"),
        ("rear_fly", "Spalle posteriori", "Spalle"), ("face_pull", "Face pull", "Spalle"),
        ("curl", "Bicipiti", "Bicipiti"), ("tri_oh", "Tricipiti · sopra la testa", "Tricipiti"), ("tri_push", "Tricipiti · push down", "Tricipiti"),
        ("squat", "Gambe · pressa", "Gambe"), ("leg_ext", "Quadricipiti", "Quadricipiti"),
        ("leg_curl", "Femorali · leg curl", "Femorali"), ("hinge", "Femorali · stacchi", "Femorali"),
        ("adductor", "Adduttori", "Adduttori"), ("abductor", "Abduttori", "Abduttori"),
        ("lunge", "Affondi", "Gambe"), ("hip_thrust", "Glutei", "Glutei"), ("calf", "Polpacci", "Polpacci"), ("core", "Addome", "Addome"),
    ]

    static func short(_ pattern: String) -> String { all.first { $0.pattern == pattern }?.short ?? "Altro" }

    /// What to choose from for a group: the user's favourites first, never the exercises they avoid.
    static func options(_ pattern: String) -> [ExerciseSwaps.Option] {
        let favourites = (Preferences.favourites[pattern] ?? []).map {
            ExerciseSwaps.Option(name: $0, pattern: pattern, cue: "Una delle tue varianti preferite.")
        }
        var seen = Set<String>()
        return (favourites + (ExerciseSwaps.options[pattern] ?? []).filter { $0.pattern == pattern })
            .filter { !Preferences.dislikes($0.name) && seen.insert($0.name.lowercased()).inserted }
    }
}

/// The plan while it is being edited: a flat list of exercises per day, each with its own sets, reps and rest.
enum PlanDraft {
    struct Item: Identifiable, Hashable {
        var id = UUID()
        var name: String
        var pattern: String
        var cue: String
        var sets = 3
        var repsMin = 8
        var repsMax = 12
        var rest = 90
        /// Alternated with the next exercise (jump set).
        var paired = false
    }

    struct Day: Identifiable, Hashable {
        var id = UUID()
        var name: String
        var items: [Item] = []
    }

    static func item(_ option: ExerciseSwaps.Option) -> Item {
        Item(name: option.name, pattern: option.pattern, cue: option.cue)
    }

    static func draft(from days: [WorkoutDay]) -> [Day] {
        days.map { day in
            var items: [Item] = []
            for block in day.blocks {
                for (i, e) in block.exercises.enumerated() {
                    items.append(Item(name: e.name, pattern: e.pattern, cue: e.cue, sets: e.sets, repsMin: e.minReps, repsMax: e.maxReps,
                                      rest: block.restSeconds, paired: i < block.exercises.count - 1))
                }
            }
            return Day(name: day.name, items: items)
        }
    }

    /// The plan the rest of the app uses: paired exercises share a block, names are unique.
    static func build(_ days: [Day]) -> [WorkoutDay] {
        var usedDays = Set<String>()
        var out: [WorkoutDay] = []
        for (n, day) in days.enumerated() where !day.items.isEmpty {
            var name = day.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { name = "Giorno \(n + 1)" }
            while !usedDays.insert(name.lowercased()).inserted { name += " bis" }
            var usedNames = Set<String>()
            let items = day.items.filter { usedNames.insert($0.name.lowercased()).inserted }
            var blocks: [ExerciseBlock] = []
            var i = 0
            while i < items.count {
                var group = [items[i]]
                if items[i].paired, i + 1 < items.count { group.append(items[i + 1]); i += 1 }
                i += 1
                let label = String(Character(UnicodeScalar(UInt8(65 + min(blocks.count, 25)))))
                blocks.append(ExerciseBlock(label: label, restSeconds: group[0].rest, exercises: group.map(exercise)))
            }
            var focus: [String] = []
            for item in items where !focus.contains(MuscleGroup.short(item.pattern)) { focus.append(MuscleGroup.short(item.pattern)) }
            out.append(WorkoutDay(name: name, focus: focus.joined(separator: " · "), blocks: blocks))
        }
        return out
    }

    private static func exercise(_ item: Item) -> Exercise {
        let low = max(1, min(item.repsMin, item.repsMax)), high = max(item.repsMin, item.repsMax)
        return Exercise(name: item.name, pattern: item.pattern, sets: max(1, item.sets), reps: low == high ? "\(low)" : "\(low)–\(high)",
                        rir: "1–2", cue: item.cue, stretch: "")
    }
}

/// The plan improves by itself (double progression, as in wger's progression rules and Liftosaur): first more
/// reps with the same load; when every set reaches the top of the range, more load and back to the bottom;
/// three sessions without progress, a lighter restart.
enum AutoProgress {
    struct Session: Equatable {
        var day: String
        var sets: [(kg: Double, reps: Int)]
        static func == (a: Session, b: Session) -> Bool { a.day == b.day && a.sets.map(\.kg) == b.sets.map(\.kg) && a.sets.map(\.reps) == b.sets.map(\.reps) }

        var top: Double { sets.map(\.kg).max() ?? 0 }
        /// Reps of the sets done with the heaviest load of the session.
        var topReps: [Int] { sets.filter { $0.kg >= top }.map(\.reps) }
    }

    enum Kind: Equatable { case first, moreReps, moreLoad, restart }

    struct Target: Equatable {
        var kind: Kind
        var kg: Double
        var reps: Int
        var message: String
    }

    /// Smallest useful jump: 1 kg for light loads, 2 kg with dumbbells, 2.5 kg otherwise.
    static func step(for name: String, kg: Double) -> Double {
        if kg < 10 { return 1 }
        return Equipment.needs(name).contains(.manubri) ? 2 : 2.5
    }

    static func sessions(_ logs: [(day: String, kg: Double, reps: Int)], before today: String = DayId.today) -> [Session] {
        Dictionary(grouping: logs.filter { $0.day < today }, by: \.day)
            .map { Session(day: $0.key, sets: $0.value.map { (kg: $0.kg, reps: $0.reps) }) }
            .sorted { $0.day < $1.day }
    }

    /// What to do today, from the sessions already done (oldest first).
    static func target(_ exercise: Exercise, history: [Session]) -> Target {
        guard let last = history.last, !last.sets.isEmpty else {
            return Target(kind: .first, kg: 0, reps: exercise.minReps,
                          message: "Prima volta: scegli un carico con cui fai \(exercise.minReps)–\(exercise.maxReps) ripetizioni fermandoti 1–2 prima del limite.")
        }
        let kg = last.top, reps = last.topReps
        let jump = step(for: exercise.name, kg: kg)
        let low = reps.min() ?? 0
        // every planned set at the top of the range: more load
        if reps.count >= exercise.sets, low >= exercise.maxReps {
            if kg <= 0 {
                return Target(kind: .moreLoad, kg: 0, reps: exercise.maxReps,
                              message: "Tutte le serie a \(exercise.maxReps): aggiungi un po' di zavorra oppure una serie.")
            }
            return Target(kind: .moreLoad, kg: kg + jump, reps: exercise.minReps,
                          message: "Tutte le serie a \(exercise.maxReps) con \(kg.it(1)) kg: oggi sali a \((kg + jump).it(1)) kg e riparti da \(exercise.minReps) ripetizioni.")
        }
        // three sessions with the same load and no more reps: lighter restart
        let recent = history.suffix(3)
        if recent.count == 3, kg > 0, recent.allSatisfy({ $0.top == kg }),
           (recent.last?.topReps.reduce(0, +) ?? 0) <= (recent.first?.topReps.reduce(0, +) ?? 0) {
            let lighter = max(jump, ((kg * 0.9) / jump).rounded() * jump)
            return Target(kind: .restart, kg: lighter, reps: exercise.maxReps,
                          message: "Fermo da 3 sedute a \(kg.it(1)) kg: oggi \(lighter.it(1)) kg puntando a \(exercise.maxReps) ripetizioni, poi risali. Se non si sblocca, cambia esercizio.")
        }
        let goal = min(exercise.maxReps, max(low + 1, exercise.minReps))
        let range = low == (reps.max() ?? low) ? "\(low)" : "\(low)–\(reps.max() ?? low)"
        let load = kg > 0 ? "Stesso carico, \(kg.it(1)) kg" : "A corpo libero"
        return Target(kind: .moreReps, kg: kg, reps: goal,
                      message: "\(load): punta a \(goal) ripetizioni per serie (l'ultima volta \(range)).")
    }

    /// For the plan overview: which exercises go up in load next time and which are stuck.
    static func summary(days: [WorkoutDay], logs: [(day: String, exercise: String, kg: Double, reps: Int)]) -> (up: [String], stuck: [String], tracked: Int) {
        var up: [String] = [], stuck: [String] = [], tracked = 0
        let byExercise = Dictionary(grouping: logs, by: \.exercise)
        for exercise in days.flatMap({ $0.blocks.flatMap(\.exercises) }) {
            let name = ExerciseSwaps.resolved(exercise).name
            let history = sessions((byExercise[name] ?? []).map { (day: $0.day, kg: $0.kg, reps: $0.reps) }, before: "9999")
            guard !history.isEmpty else { continue }
            tracked += 1
            switch target(exercise, history: history).kind {
            case .moreLoad: if !up.contains(name) { up.append(name) }
            case .restart: if !stuck.contains(name) { stuck.append(name) }
            default: break
            }
        }
        return (up, stuck, tracked)
    }
}

// MARK: Builder

/// Build the plan day by day: any exercise, any number of sets and reps, single or paired in jump sets.
struct PlanBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var plan = PlanStore.shared
    @State private var days: [PlanDraft.Day] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Ogni giorno ha i suoi esercizi con serie, ripetizioni e recupero decisi da te. Nessuno schema imposto: dopo ogni allenamento carichi e ripetizioni si aggiornano da soli.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Giorni") {
                    ForEach($days) { $day in
                        NavigationLink {
                            PlanDayEditor(day: $day)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(day.name.isEmpty ? "Senza nome" : day.name).font(.headline)
                                Text(day.items.isEmpty ? "Nessun esercizio" : "\(day.items.count) esercizi · \(day.items.reduce(0) { $0 + $1.sets }) serie")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onMove { days.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { days.remove(atOffsets: $0) }
                    Button { days.append(PlanDraft.Day(name: "Giorno \(days.count + 1)")) } label: {
                        Label("Aggiungi un giorno", systemImage: "plus.circle.fill")
                    }
                    .accessibilityIdentifier("plan-add-day")
                }
                Section {
                    Button { days = PlanDraft.draft(from: startingPoint) } label: {
                        Label("Riparti dalla scheda \(plan.source == .nomorediet ? "Tempra" : "del Calendario")", systemImage: "doc.on.doc")
                    }
                } footer: {
                    Text("Copia i giorni e gli esercizi di quella scheda: poi li cambi come vuoi.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("La mia scheda")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        let built = PlanDraft.build(days)
                        plan.customDays = built
                        if !built.isEmpty { plan.source = .custom }
                        dismiss()
                    }
                    .disabled(days.allSatisfy { $0.items.isEmpty })
                    .accessibilityIdentifier("plan-save")
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                days = PlanDraft.draft(from: plan.customDays.isEmpty ? startingPoint : plan.customDays)
            }
        }
    }

    /// The plan to copy from: the built-in or calendar one, with the user's preferences applied.
    private var startingPoint: [WorkoutDay] {
        plan.source == .nomorediet ? Preferences.personalize(WorkoutPlan.nomoredietDays) : Preferences.personalize(plan.calendarDays)
    }
}

struct PlanDayEditor: View {
    @Binding var day: PlanDraft.Day
    @State private var adding = false

    var body: some View {
        List {
            Section("Nome") {
                TextField("Es. Petto e dorso", text: $day.name)
            }
            Section {
                ForEach($day.items) { $item in
                    PlanItemRow(item: $item, isLast: item.id == day.items.last?.id)
                }
                .onMove { day.items.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { day.items.remove(atOffsets: $0) }
                Button { adding = true } label: { Label("Aggiungi un esercizio", systemImage: "plus.circle.fill") }
                    .accessibilityIdentifier("plan-add-exercise")
            } header: { Text("Esercizi") } footer: {
                Text("Tieni premuto e trascina per cambiare l'ordine, scorri a sinistra per togliere. \"Jump set\" alterna l'esercizio con quello sotto.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle(day.name.isEmpty ? "Giorno" : day.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { EditButton() } }
        .sheet(isPresented: $adding) {
            ExercisePicker(taken: Set(day.items.map { $0.name.lowercased() })) { option in
                day.items.append(PlanDraft.item(option))
            }
        }
    }
}

struct PlanItemRow: View {
    @Binding var item: PlanDraft.Item
    var isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.name).font(.headline)
            Text(MuscleGroup.short(item.pattern)).font(.caption).foregroundStyle(Theme.accent)
            Stepper("Serie: \(item.sets)", value: $item.sets, in: 1...8)
            Stepper("Ripetizioni da \(item.repsMin)", value: $item.repsMin, in: 1...30)
            Stepper("Ripetizioni fino a \(item.repsMax)", value: $item.repsMax, in: 1...40)
            Stepper("Recupero: \(item.rest) s", value: $item.rest, in: 30...300, step: 15)
            if !isLast { Toggle("Jump set con l'esercizio sotto", isOn: $item.paired) }
        }
        .font(.subheadline)
        .padding(.vertical, 4)
        .onChange(of: item.repsMin) { _, low in if item.repsMax < low { item.repsMax = low } }
        .onChange(of: item.repsMax) { _, high in if item.repsMin > high { item.repsMin = high } }
    }
}

/// Choose an exercise: by muscle group (favourites first, nothing the user avoids), from the full catalog, or by name.
struct ExercisePicker: View {
    var taken: Set<String>
    var pick: (ExerciseSwaps.Option) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var catalog = ExerciseCatalog.shared
    @State private var query = ""
    @State private var onlyFree = false

    private var busy: Set<Equipment> { onlyFree ? Equipment.busyNow : [] }

    private func shown(_ pattern: String) -> [ExerciseSwaps.Option] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return MuscleGroup.options(pattern).filter { o in
            !taken.contains(o.name.lowercased()) && (q.isEmpty || o.name.lowercased().contains(q)) && Equipment.isFree(o.name, busy: busy)
        }
    }

    private var catalogMatches: [ExerciseCatalog.Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 3 else { return [] }
        return Array(catalog.items.filter { $0.name.lowercased().contains(q) && !taken.contains($0.name.lowercased()) }.prefix(40))
    }

    var body: some View {
        NavigationStack {
            List {
                if !Equipment.busyNow.isEmpty {
                    Section { Toggle("Solo con attrezzi liberi adesso", isOn: $onlyFree) }
                }
                ForEach(MuscleGroup.all, id: \.pattern) { group in
                    let options = shown(group.pattern)
                    if !options.isEmpty {
                        Section(group.title) {
                            ForEach(options, id: \.self) { option in
                                Button { pick(option); dismiss() } label: {
                                    HStack(spacing: 12) {
                                        MovementFigure(pattern: option.pattern, size: 44, animated: false)
                                            .background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                        Text(option.name).foregroundStyle(.primary)
                                        Spacer(minLength: 4)
                                        if (Preferences.favourites[group.pattern] ?? []).contains(option.name) {
                                            Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if !catalogMatches.isEmpty {
                    Section("Dal catalogo completo") {
                        ForEach(catalogMatches) { item in
                            Button {
                                pick(ExerciseSwaps.Option(name: item.name, pattern: ExerciseCatalog.pattern(for: item), cue: item.instructions.first ?? ""))
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).foregroundStyle(.primary)
                                    Text(item.primaryMuscles.map(ExerciseCatalog.muscleName).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.count >= 3, !taken.contains(name.lowercased()) {
                    Section {
                        Button {
                            pick(ExerciseSwaps.Option(name: name, pattern: PlanParser.pattern(for: name), cue: ""))
                            dismiss()
                        } label: { Label("Aggiungi \"\(name)\" con questo nome", systemImage: "square.and.pencil") }
                    } footer: { Text("Per un esercizio che non trovi in elenco.") }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Cerca o scrivi un esercizio")
            .navigationTitle("Scegli l'esercizio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } } }
            .task { await catalog.loadIfNeeded() }
        }
    }
}
