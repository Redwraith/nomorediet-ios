import SwiftData
import SwiftUI
import UserNotifications

struct WorkoutTab: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var timer = RestTimer.shared
    @Query(sort: \SetLog.createdAt, order: .reverse) private var logs: [SetLog]
    @State private var showWhy = false
    @State private var path: [WorkoutDay] = []
    @State private var showTimer = false

    @ObservedObject private var plan = PlanStore.shared
    @State private var syncing = false
    @State private var syncMessage: String?
    @State private var showHistory = false

    /// A choice made today with the arrows ("I skipped A1, go back to it").
    @AppStorage("workout.pick." + DayId.today) private var pick = -1
    @State private var waveSets = SetWave.sets()

    private var currentIndex: Int {
        WorkoutPlan.current(logs: logs.map { (day: $0.day, exercise: $0.exercise) }, pick: pick >= 0 ? pick : nil)
    }
    /// Today's session in sequence: after the last one done, so a skipped workout is not lost.
    private var nextDay: WorkoutDay {
        WorkoutPlan.days.isEmpty ? WorkoutPlan.nomoredietDays[0] : WorkoutPlan.days[currentIndex]
    }
    private var isToday: Bool { true }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 16) {
                    if timer.isRunning { RestTimerBanner(timer: timer) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(WorkoutPlan.name).font(.title2.bold())
                        Text(WorkoutPlan.meta).font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Label(Progression.title(), systemImage: "chart.line.uptrend.xyaxis")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    todayCard
                    waveCard
                    planSourceCard
                    ForEach(WorkoutPlan.days) { day in
                        NavigationLink(value: day) {
                            DayCard(day: day, next: day == nextDay, today: isToday && day == nextDay, done: doneSets(day))
                        }
                        .buttonStyle(.plain)
                    }
                    DisclosureGroup("Perché funziona e studi", isExpanded: $showWhy) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(WorkoutPlan.why, id: \.self) { Text("• " + $0).font(.subheadline) }
                            ForEach(WorkoutPlan.refs, id: \.doi) { ref in
                                Link(destination: URL(string: "https://doi.org/\(ref.doi)")!) {
                                    VStack(alignment: .leading) {
                                        Text("\(ref.first) et al. \(ref.year) · \(ref.journal)").font(.subheadline.weight(.semibold))
                                        Text(ref.finding).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(.top, 8)
                    }
                    .padding(14)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Allenamento")
            .navigationDestination(for: WorkoutDay.self) { WorkoutDayView(day: $0) }
            .onAppear(perform: openIfAsked)
            .task { await ExerciseCatalog.shared.loadIfNeeded() }
            .onChange(of: app.openWorkout) { _, _ in openIfAsked() }
            .sheet(isPresented: $showTimer) { TimerSheet().presentationDetents([.medium]) }
            .sheet(isPresented: $showHistory) { SetHistoryView() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showTimer = true } label: { Image(systemName: "timer") }.accessibilityLabel("Timer")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }.accessibilityLabel("Storico serie: modifica o elimina")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: WorkoutPlan.text, subject: Text("Scheda Nomorediet"), preview: SharePreview(WorkoutPlan.name)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    /// Today's workout, with arrows to go back to a skipped one (or forward).
    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Oggi tocca").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button { choose(currentIndex - 1) } label: { Image(systemName: "chevron.left.circle.fill").font(.title) }
                    .accessibilityLabel("Allenamento precedente")
                    .accessibilityIdentifier("workout-prev")
                VStack(spacing: 2) {
                    Text(nextDay.name).font(.title3.bold())
                    Text(nextDay.focus).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                Button { choose(currentIndex + 1) } label: { Image(systemName: "chevron.right.circle.fill").font(.title) }
                    .accessibilityLabel("Allenamento successivo")
                    .accessibilityIdentifier("workout-next")
            }
            .foregroundStyle(Theme.accent)
            Text(pick >= 0 ? "Scelto da te. " : "Segue l'ultimo allenamento fatto: se ne salti uno, è ancora lui il prossimo. ")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if pick >= 0 {
                    Button("Torna al suggerito") { pick = -1 }.buttonStyle(.bordered).controlSize(.small)
                }
                Spacer()
                Button { path = [nextDay] } label: { Label("Inizia", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("workout-start")
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private func choose(_ index: Int) {
        let n = max(WorkoutPlan.days.count, 1)
        pick = ((index % n) + n) % n
    }

    /// 3 → 4 → 5 sets, then more weight and back to 3.
    private var waveCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Serie per esercizio questa settimana").font(.subheadline.weight(.semibold))
            Picker("Serie", selection: $waveSets) {
                Text("3 serie").tag(3)
                Text("4 serie").tag(4)
                Text("5 serie").tag(5)
            }
            .pickerStyle(.segmented)
            .onChange(of: waveSets) { _, sets in SetWave.setThisWeek(sets: sets) }
            Text("Vale per i primi due esercizi di ogni seduta (6–10 ripetizioni): ogni settimana una serie in più, 3, poi 4, poi 5. Dopo la settimana da 5 aumenti i kg e ricominci da 3. Gli altri esercizi restano al massimo 3 serie da 15. Cambia da solo ogni lunedì.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var planSourceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Scheda", selection: $plan.source) {
                Text("Dal mio Calendario").tag(PlanStore.Source.calendar)
                Text("Nomorediet").tag(PlanStore.Source.nomorediet)
            }
            .pickerStyle(.segmented)
            if plan.source == .calendar {
                HStack {
                    Text(plan.importedAt.map { "Aggiornata dal Calendario il \($0.formatted(date: .abbreviated, time: .shortened))" }
                         ?? "Scheda Ciclo 2 dal tuo Google Calendar")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        syncing = true
                        Task { syncMessage = await plan.syncFromCalendar(); syncing = false }
                    } label: {
                        if syncing { ProgressView() } else { Label("Aggiorna", systemImage: "arrow.triangle.2.circlepath") }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                if let syncMessage { Text(syncMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    /// Arriving at the gym (or a Siri request) opens today's session directly.
    private func openIfAsked() {
        guard app.openWorkout else { return }
        app.openWorkout = false
        path = [nextDay]
    }

    private func doneSets(_ day: WorkoutDay) -> Int {
        let names = Set(day.blocks.flatMap { $0.exercises.flatMap { [$0.name, ExerciseSwaps.resolved($0).name] } })
        return logs.filter { $0.day == DayId.today && names.contains($0.exercise) }.count
    }
}

struct DayCard: View {
    var day: WorkoutDay
    var next: Bool
    var today = false
    var done: Int

    var body: some View {
        HStack(spacing: 14) {
            MovementFigure(pattern: day.blocks.first?.exercises.first?.pattern ?? "squat", size: 70, animated: next)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(day.name).font(.headline).lineLimit(1)
                    if next {
                        Text(today ? "OGGI" : "PROSSIMO").font(.caption2.bold()).lineLimit(1).fixedSize()
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.accent, in: Capsule()).foregroundStyle(.white)
                    }
                }
                Text(day.focus).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                let total = WorkoutPlan.totalSets(day, phase: Progression.phase())
                Text(done > 0 ? "Oggi: \(done) di \(total) serie" : "\(day.blocks.count) jump set · \(total) serie").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(next ? Theme.accent : .clear, lineWidth: 2))
    }
}

struct WorkoutDayView: View {
    var day: WorkoutDay
    @StateObject private var timer = RestTimer.shared
    @Query private var logs: [SetLog]
    @State private var showTimer = false
    @State private var finished = false
    @State private var celebrated = false

    /// Sets done today for this day's exercises, and how many the day asks for.
    private var progress: (done: Int, total: Int, kg: Double) {
        let names = WorkoutPlan.names(day, on: DayId.today)
        let today = logs.filter { $0.day == DayId.today && names.contains($0.exercise) }
        return (today.count, WorkoutPlan.totalSets(day, phase: Progression.phase()), today.reduce(0) { $0 + $1.kg * Double($1.reps) })
    }
    /// Bumped when an exercise is swapped, to redraw the cards.
    @State private var swaps = 0

    var body: some View {
        let phase = Progression.phase()
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(day.focus).font(.headline)
                    Text(phase == .deload ? Progression.title(phase) : SetWave.title).font(.subheadline).foregroundStyle(Theme.accent)
                    Text("Primi due esercizi: 3, poi 4, poi 5 serie da 6–10 ripetizioni. Gli altri: al massimo 3 serie da 15. Dropset solo dove c'è 🔻.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(day.blocks) { block in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Jump set \(block.label)").font(.title3.bold())
                            Spacer(minLength: 8)
                            // tap the rest time to start the timer
                            Button {
                                timer.start(seconds: block.restSeconds, next: ExerciseSwaps.resolved(block.exercises[0]).name)
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            } label: {
                                Label("\(block.restSeconds) s", systemImage: "timer")
                                    .font(.subheadline.weight(.semibold)).fixedSize()
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Theme.accent.opacity(0.18), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                            .accessibilityLabel("Avvia il recupero di \(block.restSeconds) secondi")
                            .accessibilityIdentifier("rest-start-\(block.label)")
                        }
                        Text("Alterna \(block.label)1 e \(block.label)2: una serie dell'uno, \(block.restSeconds) s di recupero, una serie dell'altro.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(block.exercises.enumerated()), id: \.element.id) { index, original in
                            let exercise = ExerciseSwaps.resolved(SetWave.apply(Progression.apply(original, phase: phase), phase: phase))
                            let partner = ExerciseSwaps.resolved(block.exercises[(index + 1) % block.exercises.count])
                            ExerciseCard(label: "\(block.label)\(index + 1)", original: original, exercise: exercise, rest: block.restSeconds,
                                         next: partner, note: Progression.note(Progression.apply(original, phase: phase), phase: phase)) { swaps += 1 }
                                .id("\(original.name)-\(swaps)")
                        }
                    }
                }
                Text("\(progress.done) di \(progress.total) serie fatte")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                Button {
                    timer.stop()
                    Supplements.workoutFinished()
                    finished = true
                } label: {
                    Label("Termina allenamento", systemImage: "flag.checkered").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("workout-finish")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Theme.background.ignoresSafeArea())
        // the running timer stays visible at the top while scrolling
        .safeAreaInset(edge: .top) {
            if timer.isRunning {
                RestTimerBanner(timer: timer)
                    .background(Theme.background.opacity(0.95), in: RoundedRectangle(cornerRadius: 18))
                    .padding(.horizontal, 16).padding(.bottom, 6)
            }
        }
        .animation(.snappy, value: timer.isRunning)
        .navigationTitle(day.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showTimer = true } label: { Image(systemName: "timer") }.accessibilityLabel("Timer")
            }
        }
        .sheet(isPresented: $showTimer) { TimerSheet().presentationDetents([.medium]) }
        .sheet(isPresented: $finished) {
            FinishedView(sets: progress.done, kg: progress.kg)
                .presentationDetents([.medium])
        }
        // the last set of the day: congratulations without having to tap "Termina"
        .onChange(of: progress.done) { _, done in
            guard done >= progress.total, progress.total > 0, !celebrated else { return }
            celebrated = true
            timer.stop()
            Supplements.workoutFinished()
            finished = true
        }
    }
}

/// "Bravo, ce l'hai fatta": shown (and said aloud) when the last set is logged or the workout is ended.
struct FinishedView: View {
    var sets: Int
    var kg: Double
    @Environment(\.dismiss) private var dismiss

    private var message: String { "Bravo, ce l'hai fatta! Hai finito l'allenamento." }

    var body: some View {
        VStack(spacing: 16) {
            Text("🏆").font(.system(size: 64))
            Text("Bravo, ce l'hai fatta!").font(.largeTitle.bold()).multilineTextAlignment(.center)
            Text("Hai finito l'allenamento.").font(.title3)
            Text("\(sets) serie · \(kg.it()) kg sollevati in totale").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            if !Supplements.creatineTakenToday {
                Label("Ricordati la creatina: 5 g adesso.", systemImage: "pills.fill").font(.subheadline).foregroundStyle(.orange)
            }
            Button("Grazie!") { dismiss() }.buttonStyle(.borderedProminent).padding(.top, 6)
        }
        .padding(24)
        .onAppear {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            CoachVoice.shared.speak(message)
        }
    }
}

struct ExerciseCard: View {
    var label: String
    /// The plan exercise; `exercise` is what is done today (progression and swap applied).
    var original: Exercise
    var exercise: Exercise
    var rest: Int
    var next: Exercise
    var note: String?
    var swapped: () -> Void = {}
    @Environment(\.modelContext) private var context
    @Query private var allLogs: [SetLog]
    @StateObject private var timer = RestTimer.shared
    @State private var reps = ""
    @State private var kg = ""
    @State private var rir = 2
    @State private var countingReps = false
    @State private var choosingSwap = false
    @State private var countingWithSensors = false
    @State private var editing: SetLog?
    @State private var deleting: SetLog?
    @AppStorage("rest.extra") private var restExtra = 0
    @ObservedObject private var catalog = ExerciseCatalog.shared

    private var logs: [SetLog] { allLogs.filter { $0.exercise == exercise.name }.sorted { $0.createdAt < $1.createdAt } }
    private var today: [SetLog] { logs.filter { $0.day == DayId.today } }
    private var lastSession: [SetLog] {
        guard let lastDay = logs.last(where: { $0.day != DayId.today })?.day else { return [] }
        return logs.filter { $0.day == lastDay }
    }

    /// The illustrated animation from the exercise catalog when there is one, else the stick figure.
    @ViewBuilder private var exerciseFigure: some View {
        if let item = catalog.item(named: exercise.name) {
            CatalogFigure(id: item.id, pattern: exercise.pattern, size: 96)
        } else {
            MovementFigure(pattern: exercise.pattern, size: 96)
        }
    }

    /// Set wave: same load while the sets go 3 → 4 → 5, more weight when a new wave starts at 3 sets.
    private var suggestion: String? {
        guard let lastDay = lastSession.first?.day else { return nil }
        let best = lastSession.map(\.kg).max() ?? 0
        return SetWave.advice(lastBest: best, lastDay: lastDay)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                exerciseFigure
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 14))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(label) · \(exercise.name)").font(.headline)
                    if exercise.name != original.name {
                        Text("al posto di \(original.name)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("\(exercise.sets) × \(exercise.reps) · RIR \(exercise.rir)").font(.subheadline.monospacedDigit()).foregroundStyle(Theme.accent)
                    if let dropset = exercise.dropset {
                        Text("🔻 \(dropset) ultima serie").font(.caption.weight(.semibold)).foregroundStyle(.red)
                    }
                    Text(exercise.cue).font(.caption)
                    Label(exercise.stretch, systemImage: "arrow.left.and.right").font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Button { choosingSwap = true } label: { Label("Cambia esercizio", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.bordered).controlSize(.small)
                if exercise.name != original.name {
                    Button("Ripristina") { ExerciseSwaps.set(nil, for: original.name); swapped() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            if let note { Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let suggestion {
                Label(suggestion, systemImage: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(today) { set in
                HStack(alignment: .firstTextBaseline) {
                    Button { editing = set } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Serie \(set.index)").font(.subheadline).fixedSize()
                            Spacer(minLength: 8)
                            Text("\(set.kg.it(1)) kg × \(set.reps)\(set.partials > 0 ? " + \(set.partials) parz." : "") · RIR \(set.rir)")
                                .font(.subheadline.monospacedDigit()).multilineTextAlignment(.trailing)
                            Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Tocca per correggere")
                    Button(role: .destructive) { deleting = set } label: {
                        Image(systemName: "trash").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Elimina la serie \(set.index)")
                }
            }
            if today.count < exercise.sets + 2 {
                // two rows, so nothing overlaps on narrow screens
                HStack(spacing: 8) {
                    TextField("kg", text: $kg).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                    TextField("ripetizioni", text: $reps).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                    Menu {
                        Picker("RIR", selection: $rir) { ForEach(0..<5) { Text("RIR \($0)").tag($0) } }
                    } label: {
                        Text("RIR \(rir)").font(.subheadline.monospacedDigit()).fixedSize()
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                HStack(spacing: 8) {
                    Menu {
                        if RepCounterView.supports(exercise.pattern) {
                            Button { countingReps = true } label: { Label("Con la fotocamera", systemImage: "camera.viewfinder") }
                        }
                        Button { countingWithSensors = true } label: { Label("Con i sensori dell'iPhone", systemImage: "iphone.radiowaves.left.and.right") }
                    } label: {
                        Label("Conta", systemImage: "figure.strengthtraining.traditional")
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Theme.accent.opacity(0.18), in: Capsule())
                    }
                    .accessibilityLabel("Conta le ripetizioni")
                    .accessibilityIdentifier("count-reps-\(label)")
                    Button { logSet(partials: 0) } label: {
                        Label("Serie \(today.count + 1) fatta", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).disabled(Int(reps) == nil)
                }
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
        .onAppear {
            if let last = lastSession.last ?? logs.last { kg = last.kg.it(1) }
        }
        .sheet(item: $editing) { set in SetEditSheet(set: set).presentationDetents([.medium]) }
        .confirmationDialog("Eliminare questa serie?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Elimina", role: .destructive) {
                if let set = deleting { context.delete(set); renumber() }
                deleting = nil
            }
        }
        .sheet(isPresented: $choosingSwap) {
            SwapSheet(original: original, current: exercise) { option in
                ExerciseSwaps.set(option, for: original.name)
                choosingSwap = false
                swapped()
            }
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $countingWithSensors) {
            MotionRepCounterView(exercise: exercise.name, target: exercise.maxReps) { counted in
                countingWithSensors = false
                guard let counted, counted > 0 else { return }
                reps = String(counted)
                logSet(partials: 0)
            }
        }
        .fullScreenCover(isPresented: $countingReps) {
            RepCounterView(pattern: exercise.pattern, exercise: exercise.name, target: exercise.maxReps) { result in
                countingReps = false
                guard let result, let full = result["full"] as? Int else { return }
                reps = String(full)
                if let r = result["rir"] as? String, let value = Int(r.prefix(1)) { rir = value }
                logSet(partials: result["partial"] as? Int ?? 0)
            }
            .ignoresSafeArea()
        }
    }

    private func logSet(partials: Int) {
        guard let r = Int(reps) else { return }
        context.insert(SetLog(day: DayId.today, exercise: exercise.name, index: today.count + 1, reps: r,
                              kg: kg.italianDouble ?? 0, rir: rir, partials: partials))
        reps = ""
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Hero.award(.workout)
        markTrainingDay()
        Supplements.markTrained()
        timer.start(seconds: max(15, rest + restExtra), next: "\(next.name)")
    }

    /// Keeps "Serie 1, 2, 3…" in order after a deletion.
    private func renumber() {
        for (i, set) in today.filter({ $0 != deleting }).enumerated() { set.index = i + 1 }
    }

    private func markTrainingDay() {
        let today = DayId.today
        let infos = (try? context.fetch(FetchDescriptor<DayInfo>(predicate: #Predicate { $0.day == today }))) ?? []
        if let info = infos.first { info.kind = .training } else { context.insert(DayInfo(day: today, kind: .training)) }
    }
}

/// Rest timer between the two exercises of a jump set, mirrored in a Live Activity.
final class RestTimer: ObservableObject {
    static let shared = RestTimer()
    @Published private(set) var end: Date?
    @Published private(set) var next = ""
    private var tick: Timer?

    var isRunning: Bool { end.map { $0 > .now } ?? false }

    func start(seconds: Int, next: String) {
        let end = Date.now.addingTimeInterval(TimeInterval(seconds))
        self.end = end
        self.next = next
        LiveTimer.start(end: end, next: next)
        scheduleDone(at: end)
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self, let end = self.end else { return t.invalidate() }
            if end <= .now {
                t.invalidate()
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                self.stop()
            }
        }
    }

    func add(_ seconds: Int) {
        guard let end else { return }
        start(seconds: max(5, Int(end.timeIntervalSinceNow) + seconds), next: next)
    }

    func stop() {
        end = nil
        tick?.invalidate()
        LiveTimer.stop()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["rest"])
    }

    /// A notification in case the app is in the background when the rest ends.
    private func scheduleDone(at date: Date) {
        let content = UNMutableNotificationContent()
        content.title = "Recupero finito"
        content.body = "Tocca a: \(next)"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "rest", content: content, trigger: trigger))
    }
}

struct RestTimerBanner: View {
    @ObservedObject var timer: RestTimer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                if let end = timer.end, end > .now {
                    Text(timerInterval: Date.now...end, countsDown: true)
                        .font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recupero").font(.caption).foregroundStyle(.secondary)
                    Text(timer.next.isEmpty ? "Timer" : "Poi: \(timer.next)").font(.subheadline.weight(.semibold)).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Button("−15 s") { timer.add(-15) }.buttonStyle(.bordered)
                Button("+15 s") { timer.add(15) }.buttonStyle(.bordered)
                Spacer()
                Button("Salta") { timer.stop() }.buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(Theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 18))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Free timer: presets or a custom time, shown in the Dynamic Island and on Apple Watch.
struct TimerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var timer = RestTimer.shared
    @AppStorage("rest.extra") private var restExtra = 0
    @State private var minutes = 1
    @State private var seconds = 30
    private let presets = [30, 45, 60, 90, 120, 180, 300]

    var body: some View {
        NavigationStack {
            Form {
                if timer.isRunning { RestTimerBanner(timer: timer).listRowInsets(EdgeInsets()) }
                Section("Avvio rapido") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72))], spacing: 8) {
                        ForEach(presets, id: \.self) { s in
                            Button(s < 60 ? "\(s) s" : s % 60 == 0 ? "\(s / 60) min" : "\(s / 60):\(String(format: "%02d", s % 60))") {
                                start(s)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Personalizzato") {
                    HStack {
                        Picker("Minuti", selection: $minutes) { ForEach(0..<16) { Text("\($0) min").tag($0) } }.pickerStyle(.wheel)
                        Picker("Secondi", selection: $seconds) { ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text("\($0) s").tag($0) } }.pickerStyle(.wheel)
                    }
                    .frame(height: 120)
                    Button("Avvia \(minutes) min \(seconds) s") { start(minutes * 60 + seconds) }
                        .disabled(minutes * 60 + seconds < 5)
                }
                Section {
                    Stepper("Recupero automatico: \(restExtra >= 0 ? "+" : "")\(restExtra) s", value: $restExtra, in: -60...120, step: 15)
                } footer: {
                    Text("Si aggiunge al recupero della scheda quando segni una serie. Il timer compare nella Dynamic Island, sulla schermata di blocco e sull'Apple Watch.")
                }
            }
            .navigationTitle("Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Chiudi") { dismiss() } } }
        }
    }

    private func start(_ s: Int) {
        timer.start(seconds: s, next: timer.isRunning ? timer.next : "")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        dismiss()
    }
}

/// Alternatives for a busy machine, each with its animation.
struct SwapSheet: View {
    var original: Exercise
    var current: Exercise
    var pick: (ExerciseSwaps.Option?) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Stesse serie e ripetizioni, stessi muscoli. Vale solo per oggi.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(ExerciseSwaps.alternatives(for: original), id: \.self) { option in
                    Button { pick(option.name == original.name ? nil : option) } label: {
                        HStack(spacing: 12) {
                            MovementFigure(pattern: option.pattern, size: 64)
                                .background(Theme.background, in: RoundedRectangle(cornerRadius: 12))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.name).font(.headline)
                                Text(option.cue).font(.caption).foregroundStyle(.secondary)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            if option.name == current.name { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                    .buttonStyle(.plain)
                }
                CatalogSwapSection(pattern: original.pattern) { pick($0) }
            }
            .navigationTitle("Al posto di \(original.name)")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Camera rep counter (Vision body pose).
struct RepCounterView: UIViewControllerRepresentable {
    static func supports(_ pattern: String) -> Bool { RepCounterViewController.motion(for: pattern) != nil }
    var pattern: String
    var exercise: String
    var target: Int
    var done: ([String: Any]?) -> Void

    func makeUIViewController(context: Context) -> RepCounterViewController {
        let controller = RepCounterViewController(pattern: pattern, exercise: exercise, target: target)
        controller.completion = done
        return controller
    }
    func updateUIViewController(_ controller: RepCounterViewController, context: Context) {}
}

/// Correct a logged set: weight, reps, RIR, or delete it.
struct SetEditSheet: View {
    @Bindable var set: SetLog
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var kg = ""
    @State private var reps = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(set.exercise) {
                    HStack {
                        Text("Peso")
                        Spacer()
                        TextField("kg", text: $kg).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                        Text("kg").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Ripetizioni")
                        Spacer()
                        TextField("rip.", text: $reps).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90)
                    }
                    Stepper("RIR \(set.rir)", value: $set.rir, in: 0...5)
                    Stepper("Mezze ripetizioni: \(set.partials)", value: $set.partials, in: 0...20)
                }
                Section {
                    Button("Elimina questa serie", role: .destructive) {
                        context.delete(set)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Correggi serie \(set.index)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        if let value = kg.italianDouble { set.kg = value }
                        if let value = Int(reps), value > 0 { set.reps = value }
                        dismiss()
                    }
                }
            }
            .onAppear { kg = set.kg.it(1); reps = String(set.reps) }
        }
    }
}

/// Every logged set by day: tap to correct, swipe to delete, or delete a whole day.
struct SetHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \SetLog.createdAt, order: .reverse) private var logs: [SetLog]
    @State private var editing: SetLog?
    @State private var deletingDay: String?

    private var days: [String] {
        var seen = Set<String>()
        return logs.map(\.day).filter { seen.insert($0).inserted }
    }

    var body: some View {
        NavigationStack {
            List {
                if logs.isEmpty {
                    Text("Nessuna serie registrata.").foregroundStyle(.secondary)
                }
                ForEach(days, id: \.self) { day in
                    Section {
                        let sets = logs.filter { $0.day == day }.sorted { ($0.exercise, $0.index) < ($1.exercise, $1.index) }
                        ForEach(sets) { set in
                            Button { editing = set } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(set.exercise).font(.subheadline.weight(.semibold))
                                        Text("Serie \(set.index)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(set.kg.it(1)) kg × \(set.reps) · RIR \(set.rir)").font(.subheadline.monospacedDigit())
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in offsets.map { sets[$0] }.forEach(context.delete) }
                    } header: {
                        HStack {
                            Text(DayId.label(day))
                            Spacer()
                            Button("Elimina giorno", role: .destructive) { deletingDay = day }.font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Storico serie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
            .sheet(item: $editing) { set in SetEditSheet(set: set).presentationDetents([.medium]) }
            .confirmationDialog("Eliminare tutte le serie di questo giorno?", isPresented: Binding(get: { deletingDay != nil }, set: { if !$0 { deletingDay = nil } }), titleVisibility: .visible) {
                Button("Elimina tutte", role: .destructive) {
                    logs.filter { $0.day == deletingDay }.forEach(context.delete)
                    deletingDay = nil
                }
            }
        }
    }
}

