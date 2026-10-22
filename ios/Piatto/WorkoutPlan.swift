import SwiftUI

/// One exercise of a workout day.
struct Exercise: Identifiable, Hashable, Codable {
    /// Fundamental (first pair of the day), complementary (other compound lifts) or isolation: each month of the
    /// cycle changes sets and reps by role.
    enum Role: String, Codable { case fondamentale, complementare, isolamento }

    var id: String { name }
    var name: String
    var pattern: String
    var sets: Int
    var reps: String
    var rir: String
    var cue: String
    var stretch: String
    var role: Role = .complementare
    /// "Dropset -25%" on the last set, when the plan has one.
    var dropset: String? = nil
    /// Alternatives written in the plan for when the machine is busy.
    var busy: [String] = []

    /// Top of the rep range, for progression.
    var maxReps: Int { Int(reps.split(whereSeparator: { !$0.isNumber }).last ?? "") ?? 12 }
    var minReps: Int { Int(reps.split(whereSeparator: { !$0.isNumber }).first ?? "") ?? 8 }
}

struct ExerciseBlock: Identifiable, Hashable, Codable {
    var id: String { label }
    var label: String
    var restSeconds: Int
    var exercises: [Exercise]
}

struct WorkoutDay: Identifiable, Hashable, Codable {
    var id: String { name }
    var name: String
    var focus: String
    var blocks: [ExerciseBlock]
}

struct Reference: Hashable {
    var first: String
    var year: String
    var journal: String
    var doi: String
    var finding: String
}

enum WorkoutPlan {
    /// The plan in use: the user's Google Calendar plan, or Nomorediet's shoulder-and-back plan.
    static var days: [WorkoutDay] { PlanStore.shared.days }
    static var name: String { PlanStore.shared.name }
    static var meta: String {
        PlanStore.shared.source == .calendar
            ? "\(days.count) sedute a settimana · esercizi a coppie in jump set · dropset dove indicato"
            : "4 sedute da circa 55–60 minuti · priorità a spalle e dorso · esercizi a coppie in jump set · enfasi sul muscolo in allungamento"
    }

    /// The day to train on `date`: training weekdays from Profile, in order, map to the plan's days.
    static func day(on date: Date = .now, profile: Profile = ProfileStore.shared.profile) -> WorkoutDay? {
        let order = [2, 3, 4, 5, 6, 7, 1] // Monday first
        let weekdays = order.filter(profile.trainingWeekdaySet.contains)
        let today = Calendar.current.component(.weekday, from: date)
        guard let index = weekdays.firstIndex(of: today), !days.isEmpty else { return nil }
        return days[index % days.count]
    }

    private static func e(_ name: String, _ pattern: String, _ sets: Int, _ reps: String, _ rir: String, _ cue: String, _ stretch: String) -> Exercise {
        Exercise(name: name, pattern: pattern, sets: sets, reps: reps, rir: rir, cue: cue, stretch: stretch)
    }

    // Priority on shoulders and back (lagging): back twice a week with lat pulldown, neutral-grip lat machine and
    // single-arm cable row; lateral raises 4 times a week; rear delts (face pull, reverse fly) twice.
    /// For women: glutes and legs first, toned shoulders and back, four days.
    static let womenDays: [WorkoutDay] = [
        WorkoutDay(name: "Giorno 1", focus: "Glutei e femorali", blocks: [
            ExerciseBlock(label: "A", restSeconds: 90, exercises: [
                e("Hip thrust", "hip_thrust", 4, "8–12", "1–2", "Mento in basso, spingi con i talloni, 1 s di stretta in alto.", "Scendi con il bacino fino quasi a terra."),
                e("Alzate laterali al cavo", "raise_l", 3, "12–20", "0–1", "Sali lento fino all'altezza delle spalle.", "Parti con il braccio davanti al bacino.")]),
            ExerciseBlock(label: "B", restSeconds: 75, exercises: [
                e("Stacco rumeno con manubri", "hinge", 3, "8–12", "1–2", "Anche indietro, schiena neutra, manubri vicini alle gambe.", "Scendi finché senti tirare i femorali."),
                e("Abductor machine", "abductor", 3, "15–20", "1", "Apri le gambe e tieni 1 s in fuori.", "Busto leggermente in avanti per i glutei.")]),
            ExerciseBlock(label: "C", restSeconds: 60, exercises: [
                e("Leg curl da seduto", "leg_curl", 3, "10–15", "1", "Busto in avanti, controlla la risalita.", "Lascia distendere completamente il ginocchio."),
                e("Crunch al cavo", "core", 3, "12–15", "1", "Arrotola la colonna.", "Torna su ben disteso.")]),
        ]),
        WorkoutDay(name: "Giorno 2", focus: "Dorso, spalle e braccia", blocks: [
            ExerciseBlock(label: "A", restSeconds: 90, exercises: [
                e("Lat machine presa neutra", "pull_v", 3, "8–12", "1–2", "Gomiti verso i fianchi, petto alto.", "In alto lascia salire le scapole."),
                e("Shoulder press con manubri", "push_v", 3, "8–12", "1–2", "Spingi dritto sopra la testa.", "Scendi fino a sotto il mento.")]),
            ExerciseBlock(label: "B", restSeconds: 75, exercises: [
                e("Rematore monolaterale al cavo", "pull_h", 3, "10–12", "1", "Gomito verso l'anca.", "In avanti lascia allungare il dorsale."),
                e("Panca inclinata con manubri", "push_h", 3, "10–12", "1–2", "Scendi controllato fino al petto.", "Breve pausa in basso.")]),
            ExerciseBlock(label: "C", restSeconds: 60, exercises: [
                e("Push-down al cavo", "tri_push", 3, "12–15", "1", "Gomiti fermi ai fianchi.", "Risali oltre i 90°."),
                e("Curl con manubri", "curl", 3, "12–15", "1", "Gomiti fermi.", "Scendi a braccio disteso.")]),
        ]),
        WorkoutDay(name: "Giorno 3", focus: "Quadricipiti e glutei", blocks: [
            ExerciseBlock(label: "A", restSeconds: 90, exercises: [
                e("Leg press piedi alti", "squat", 4, "10–12", "1–2", "Piedi alti e larghi, spingi con i talloni.", "Scendi finché il bacino resta appoggiato."),
                e("Face pull al cavo", "face_pull", 3, "12–20", "1", "Corda verso la fronte, gomiti alti.", "Lascia distendere le braccia.")]),
            ExerciseBlock(label: "B", restSeconds: 75, exercises: [
                e("Affondi in camminata", "lunge", 3, "10–12 per gamba", "1–2", "Passo lungo, busto leggermente inclinato.", "Ginocchio dietro vicino a terra."),
                e("Calf raise in piedi", "calf", 3, "12–15", "0–1", "Ritmo lento.", "Pausa con il tallone in basso.")]),
            ExerciseBlock(label: "C", restSeconds: 60, exercises: [
                e("Leg extension", "leg_ext", 3, "12–15", "0–1", "Sali fino quasi a distendere.", "Scendi a ginocchio piegato."),
                e("Adductor machine", "adductor", 3, "15–20", "1", "Chiudi controllando.", "Apri senza fastidio all'inguine.")]),
        ]),
        WorkoutDay(name: "Giorno 4", focus: "Glutei e spalle", blocks: [
            ExerciseBlock(label: "A", restSeconds: 90, exercises: [
                e("Hip thrust alla macchina", "hip_thrust", 4, "10–15", "1", "1 s di stretta in alto.", "Scendi controllando."),
                e("Alzate laterali con manubri", "raise_l", 3, "12–20", "0–1", "Fino all'altezza delle spalle.", "Braccio leggermente davanti.")]),
            ExerciseBlock(label: "B", restSeconds: 75, exercises: [
                e("Kickback al cavo", "hip_thrust", 3, "12–15 per gamba", "1", "Spingi la gamba indietro con il gluteo, busto fermo.", "Riporta il ginocchio avanti per allungare il gluteo."),
                e("Pulley basso", "pull_h", 3, "10–12", "1", "Maniglia all'ombelico.", "Lascia andare le braccia in avanti.")]),
            ExerciseBlock(label: "C", restSeconds: 60, exercises: [
                e("Abductor machine", "abductor", 3, "15–20", "1", "Apri e tieni 1 s.", "Torna dentro lentamente."),
                e("Plank", "core", 3, "30–45 s", "1", "Glutei contratti, schiena neutra.", "Respira senza perdere la posizione.")]),
        ]),
    ]

    static let nomoredietDays: [WorkoutDay] = [
        WorkoutDay(name: "Giorno 1", focus: "Upper A · dorso e petto", blocks: [
            ExerciseBlock(label: "A", restSeconds: 90, exercises: [
                e("Lat machine presa neutra", "pull_v", 3, "6–10", "1–2", "Tira i gomiti verso i fianchi, petto alto.", "In alto lascia salire le scapole e senti il dorsale tirare."),
                e("Panca inclinata con manubri", "push_h", 3, "6–10", "1–2", "Scendi finché i manubri sono all'altezza del petto, 1 s di pausa in basso.", "La discesa profonda allunga il gran pettorale: non accorciarla.")]),
            ExerciseBlock(label: "B", restSeconds: 75, exercises: [
                e("Rematore monolaterale al cavo", "pull_h", 3, "10–12", "1", "Un braccio alla volta, tira il gomito verso l'anca, busto fermo.", "Lascia andare il braccio in avanti e ruota leggermente il busto: il dorsale si allunga."),
                e("Alzate laterali con manubri", "raise_l", 3, "12–20", "0–1", "Sali fino all'altezza delle spalle, mignolo non più alto del pollice.", "Parti con il braccio leggermente davanti al corpo.")]),
            ExerciseBlock(label: "C", restSeconds: 60, exercises: [
                e("Estensioni tricipiti sopra la testa al cavo", "tri_oh", 3, "10–15", "1", "Gomiti vicini alla testa, braccio fermo.", "Braccio sopra la testa = capo lungo del tricipite in allungamento."),
                e("Curl su panca inclinata", "curl", 3, "10–15", "1", "Braccia dietro il busto, sali senza portare avanti il gomito.", "Partenza a braccio disteso dietro al corpo.")]),
        ]),
        WorkoutDay(name: "Giorno 2", focus: "Lower A · quadricipiti e femorali", blocks: [
            ExerciseBlock(label: "A", restSeconds: 90, exercises: [
                e("Squat (goblet o bilanciere)", "squat", 3, "6–10", "1–2", "Scendi sotto il parallelo con busto stabile.", "Fermati 1 s nel punto più basso."),
                e("Alzate laterali al cavo", "raise_l", 3, "12–20", "0–1", "Cavo dietro al corpo, sali lento fino all'altezza delle spalle.", "Parti con il braccio davanti al bacino: il deltoide lavora già allungato.")]),
            ExerciseBlock(label: "B", restSeconds: 75, exercises: [
                e("Stacco rumeno", "hinge", 3, "8–10", "1–2", "Anche indietro, schiena neutra, bilanciere vicino alle gambe.", "Scendi finché senti tirare i femorali, a metà tibia circa."),
                e("Calf raise in piedi", "calf", 3, "10–15", "0–1", "Sali sulle punte in modo controllato.", "2 s di pausa con il tallone in basso, poi mezze ripetizioni basse a fine serie.")]),
            ExerciseBlock(label: "C", restSeconds: 60, exercises: [
                e("Leg curl da seduto", "leg_curl", 3, "10–15", "1", "Busto inclinato in avanti, controlla la risalita.", "Da seduto il femorale lavora più allungato che da sdraiato."),
                e("Alzate posteriori al cavo", "rear_fly", 3, "12–20", "0–1", "Busto inclinato, apri le braccia indietro con i gomiti morbidi.", "Lascia incrociare le braccia davanti: il deltoide posteriore parte allungato.")]),
        ]),
        WorkoutDay(name: "Giorno 3", focus: "Upper B · spalle e dorso", blocks: [
            ExerciseBlock(label: "A", restSeconds: 90, exercises: [
                e("Lat pulldown presa larga", "pull_v", 3, "6–10", "1–2", "Porta la barra al petto alto, gomiti verso il basso e indietro.", "Braccia completamente distese in alto a ogni ripetizione."),
                e("Lento avanti con manubri", "push_v", 3, "6–10", "1–2", "Glutei contratti, spingi dritto sopra la testa.", "Scendi fino a sotto il mento.")]),
            ExerciseBlock(label: "B", restSeconds: 75, exercises: [
                e("Rematore monolaterale al cavo basso", "pull_h", 3, "10–12", "1", "Cavo basso, tira verso l'anca tenendo il busto fermo.", "In avanti lascia allungare il dorsale prima di ogni ripetizione."),
                e("Panca piana con manubri", "push_h", 3, "8–12", "1–2", "Scapole strette, scendi fino al petto.", "Breve pausa in basso.")]),
            ExerciseBlock(label: "C", restSeconds: 60, exercises: [
                e("Alzate laterali al cavo", "raise_l", 3, "12–20", "0–1", "Un braccio alla volta, sali lento fino all'altezza delle spalle.", "Parti con il braccio davanti al bacino."),
                e("Push-down al cavo", "tri_push", 3, "12–15", "1", "Gomiti fermi ai fianchi.", "Risali fino a superare i 90° al gomito.")]),
            ExerciseBlock(label: "D", restSeconds: 60, exercises: [
                e("Face pull al cavo", "face_pull", 3, "12–20", "1", "Corda all'altezza degli occhi, tira verso la fronte aprendo i gomiti.", "Lascia distendere le braccia in avanti a ogni ripetizione."),
                e("Curl al cavo dietro il corpo (Bayesian)", "curl", 3, "10–15", "1", "Cavo alle spalle, gomito leggermente dietro al busto.", "Il bicipite parte allungato: è la versione più efficace del curl.")]),
        ]),
        WorkoutDay(name: "Giorno 4", focus: "Lower B · glutei e polpacci", blocks: [
            ExerciseBlock(label: "A", restSeconds: 75, exercises: [
                e("Hip thrust", "hip_thrust", 3, "8–12", "1–2", "Mento in basso, spingi con i talloni, 1 s di stretta in alto.", "Scendi con il bacino fino quasi a terra."),
                e("Alzate laterali al cavo", "raise_l", 3, "12–20", "0–1", "Cavo dietro al corpo, sali lento fino all'altezza delle spalle.", "Parti con il braccio davanti al bacino: il deltoide lavora già allungato.")]),
            ExerciseBlock(label: "B", restSeconds: 90, exercises: [
                e("Leg press piedi alti", "squat", 3, "10–12", "1–2", "Piedi in alto e larghi sulla pedana, spingi con i talloni.", "Scendi finché il bacino resta appoggiato: glutei e femorali in allungamento."),
                e("Calf raise in piedi", "calf", 3, "10–15", "0–1", "Ritmo lento, niente rimbalzi.", "Mezze ripetizioni nella metà bassa a fine serie.")]),
            ExerciseBlock(label: "C", restSeconds: 60, exercises: [
                e("Leg curl da seduto", "leg_curl", 3, "10–15", "1", "Busto in avanti, punte verso di te.", "Lascia distendere completamente il ginocchio."),
                e("Leg extension", "leg_ext", 3, "12–15", "0–1", "Schienale reclinato, sali fino quasi a distendere.", "A fine serie aggiungi mezze ripetizioni nella metà con ginocchio piegato.")]),
        ]),
    ]

    static let why = [
        "Jump set: alterni due esercizi che non usano gli stessi muscoli (spinta/tirata, gambe/spalle). Riposi tra uno e l'altro, così la seduta dura circa la metà senza perdere ripetizioni.",
        "Allungamento: ogni esercizio è scelto o eseguito per caricare il muscolo quando è lungo (discese profonde, braccio sopra la testa, leg curl da seduto). A fine serie puoi aggiungere mezze ripetizioni nella parte allungata.",
        "Volume: circa 10–16 serie a settimana per gruppo muscolare, ognuno allenato 2 volte, con 0–2 ripetizioni di riserva (RIR). Spalle e dorso hanno la priorità: dorso 2 volte con lat pulldown, lat machine presa neutra e rematore monolaterale al cavo; alzate laterali 4 volte a settimana; deltoide posteriore 2 volte.",
        "Progressione a mesi, come nella tua scheda: mese 1 serie e ripetizioni base (+1 ripetizione o +2,5 kg a settimana), mese 2 tempo 3-1-1-0 con carichi −10%, mese 3 intensificatori (rest-pause e dropset doppi), con una settimana di scarico alla fine di ogni mese.",
        "Doppia progressione: quando fai il massimo delle ripetizioni in tutte le serie al RIR indicato, aumenta il carico del 2,5–5%.",
    ]

    static let refs = [
        Reference(first: "Wolf", year: "2025", journal: "PeerJ", doi: "10.7717/peerj.18904", finding: "Le mezze ripetizioni in allungamento danno la stessa crescita del movimento completo: conta enfatizzare la posizione allungata."),
        Reference(first: "McMahon", year: "2026", journal: "J Strength Cond Res", doi: "10.1519/JSC.0000000000005561", finding: "Parziali a muscolo lungo con carichi moderati: ipertrofia simile al ROM completo con carichi alti."),
        Reference(first: "Chien", year: "2026", journal: "J Funct Morphol Kinesiol", doi: "10.3390/jfmk11030370", finding: "Revisione sui paired set: alternare gli esercizi durante il recupero riduce la durata della seduta del 45–50%."),
        Reference(first: "Janicijevic", year: "2026", journal: "J Sports Sci", doi: "10.1080/02640414.2026.2637204", finding: "Superset contro serie tradizionali: adattamenti simili con molto meno tempo di recupero."),
        Reference(first: "Brummer", year: "2026", journal: "Front Public Health", doi: "10.3389/fpubh.2026.1872337", finding: "Strategie per allenarsi in meno tempo, superset compresi, mantenendo l'efficacia."),
    ]

    /// Exercises Nomorediet adds to the last session of the Calendar plan (femorali/glutei had only 4).
    static let lastDayExtras: [ExerciseBlock] = [
        ExerciseBlock(label: "3", restSeconds: 75, exercises: [
            role(e("Hip thrust", "hip_thrust", 3, "8–12", "1–2", "Mento in basso, spingi con i talloni, 1 s di stretta in alto.", "Scendi con il bacino fino quasi a terra."), .complementare),
            role(e("Calf raise in piedi", "calf", 3, "10–15", "0–1", "Sali sulle punte in modo controllato, niente rimbalzi.", "2 s di pausa con il tallone in basso."), .isolamento)]),
        ExerciseBlock(label: "4", restSeconds: 60, exercises: [
            role(e("Hyperextension 45° per glutei", "hinge", 3, "12–15", "1", "Schiena tonda leggera, spingi il bacino contro il cuscino stringendo i glutei.", "Scendi finché senti tirare i femorali."), .isolamento),
            role(e("Crunch al cavo", "core", 3, "12–15", "1", "Inginocchiato, arrotola la colonna portando i gomiti verso le ginocchia.", "In alto lascia allungare l'addome prima di ogni ripetizione."), .isolamento)]),
    ]

    private static func role(_ exercise: Exercise, _ role: Exercise.Role) -> Exercise {
        var e = exercise
        e.role = role
        return e
    }

    /// The Calendar plan with the extra exercises on its last session (only when that session is short).
    static func withExtras(_ days: [WorkoutDay]) -> [WorkoutDay] {
        guard var last = days.last, last.blocks.flatMap(\.exercises).count <= 4 else { return days }
        let used = Set(last.blocks.map(\.label))
        for var block in lastDayExtras {
            if used.contains(block.label) { block.label += "+" }
            last.blocks.append(block)
        }
        return Array(days.dropLast()) + [last]
    }

    static func totalSets(_ day: WorkoutDay, phase: Progression.Phase) -> Int {
        day.blocks.flatMap(\.exercises).reduce(0) { $0 + SetWave.apply(Progression.apply($1, phase: phase), phase: phase).sets }
    }

    /// Names a day's sets can be logged under on `logDay`: the plan exercise, its alternatives, the swap used that day.
    static func names(_ day: WorkoutDay, on logDay: String) -> Set<String> {
        Set(day.blocks.flatMap { $0.exercises.flatMap { e in [e.name] + e.busy + [ExerciseSwaps.swap(for: e.name, day: logDay)?.name].compactMap { $0 } } })
    }

    /// The plan day a session belongs to: the one with the most of its exercises logged.
    static func dayIndex(exercises: Set<String>, on logDay: String) -> Int? {
        let scores = days.enumerated().map { ($0.offset, names($0.element, on: logDay).intersection(exercises).count) }
        guard let best = scores.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }

    /// Today's workout follows the sequence, not the weekday: a skipped session is simply the next one.
    /// Today's sets decide it if any; otherwise the day after the last session; with no history, the weekday.
    /// `pick` is a choice made today with the arrows.
    static func current(logs: [(day: String, exercise: String)], today: String = DayId.today, pick: Int? = nil) -> Int {
        guard !days.isEmpty else { return 0 }
        if let pick { return ((pick % days.count) + days.count) % days.count }
        let todayNames = Set(logs.filter { $0.day == today }.map(\.exercise))
        if !todayNames.isEmpty, let i = dayIndex(exercises: todayNames, on: today) { return i }
        if let lastDay = logs.map(\.day).filter({ $0 < today }).max() {
            let names = Set(logs.filter { $0.day == lastDay }.map(\.exercise))
            if let i = dayIndex(exercises: names, on: lastDay) { return (i + 1) % days.count }
        }
        let weekday = day(on: DayId.date(today)).flatMap { d in days.firstIndex(of: d) }
        return weekday ?? 0
    }

    /// Plain text of the plan, for sharing.
    static var text: String {
        var out = ["NOMOREDIET · \(name)", meta, ""]
        for day in days {
            out.append("\(day.name.uppercased()) – \(day.focus)")
            for block in day.blocks {
                out.append("  Jump set \(block.label) · recupero \(block.restSeconds) s tra un esercizio e l'altro")
                for (i, ex) in block.exercises.enumerated() {
                    out.append("   \(block.label)\(i + 1). \(ex.name): \(ex.sets) × \(ex.reps), RIR \(ex.rir)\(ex.dropset.map { " · " + $0 + " ultima serie" } ?? "")")
                    out.append("       Tecnica: \(ex.cue)")
                    out.append("       Allungamento: \(ex.stretch)")
                }
            }
            out.append("")
        }
        out.append("PERCHÉ FUNZIONA")
        out += why.map { "• " + $0 }
        out.append("")
        out.append("STUDI")
        out += refs.map { "• \($0.first) et al. \($0.year), \($0.journal). doi.org/\($0.doi) – \($0.finding)" }
        return out.joined(separator: "\n")
    }
}

/// Side-view anime-style character looping between the two key positions of a movement: cel shading with
/// dark outlines, spiky hair, motion afterimages, speed lines, a glow on the working muscle and impact
/// sparks at the hardest point of each rep. Joint angles are interpolated with an ease-in-out curve.
struct MovementFigure: View {
    var pattern: String
    var size: CGFloat = 110
    var animated = true

    struct Pose {
        var hip: CGPoint? = nil
        var ankle: CGPoint? = nil
        var shinUp = 0.0, thighUp = 0.0
        var thigh = 0.0, shin = 0.0
        var torso = 0.0, ua = 180.0, fa = 180.0, neck = 0.0, foot = 90.0
        var leg2: (Double, Double)? = nil
        var bench = false, seat = false

        static func mix(_ a: Pose, _ b: Pose, _ t: Double) -> Pose {
            func l(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
            func p(_ x: CGPoint?, _ y: CGPoint?) -> CGPoint? {
                guard let x, let y else { return x ?? y }
                return CGPoint(x: l(x.x, y.x), y: l(x.y, y.y))
            }
            var r = a
            r.hip = p(a.hip, b.hip); r.ankle = p(a.ankle, b.ankle)
            r.shinUp = l(a.shinUp, b.shinUp); r.thighUp = l(a.thighUp, b.thighUp)
            r.thigh = l(a.thigh, b.thigh); r.shin = l(a.shin, b.shin)
            r.torso = l(a.torso, b.torso); r.ua = l(a.ua, b.ua); r.fa = l(a.fa, b.fa)
            r.neck = l(a.neck, b.neck); r.foot = l(a.foot, b.foot)
            if let x = a.leg2, let y = b.leg2 { r.leg2 = (l(x.0, y.0), l(x.1, y.1)) }
            return r
        }
    }

    private static let up = Pose(ankle: CGPoint(x: 46, y: 91))

    private static func poses(_ pattern: String) -> (Pose, Pose) {
        var a = up, b = up
        switch pattern {
        case "squat":
            a.torso = 4; a.ua = 165; a.fa = 20
            b.shinUp = 30; b.thighUp = -80; b.torso = 40; b.ua = 160; b.fa = 22
        case "hinge":
            a.shinUp = 4; a.thighUp = -4; a.torso = 4
            b.shinUp = 8; b.thighUp = -22; b.torso = 74; b.neck = -25
        case "lunge":
            a.ankle = CGPoint(x: 60, y: 91); a.shinUp = 4; a.thighUp = -14; a.torso = 2; a.leg2 = (200, 212)
            b.ankle = CGPoint(x: 60, y: 91); b.shinUp = 16; b.thighUp = -84; b.torso = 6; b.leg2 = (176, 262)
        case "push_h", "fly":
            a = Pose(hip: CGPoint(x: 64, y: 67), thigh: 100, shin: 180, torso: -90, ua: 2, fa: 2, bench: true)
            b = a
            if pattern == "fly" { b.ua = -70; b.fa = -40 } else { b.ua = 160; b.fa = 8 }
        case "push_v":
            a.ua = 168; a.fa = 6; b.ua = 8; b.fa = 4
        case "pull_h":
            a.shinUp = 14; a.thighUp = -40; a.torso = 68; a.neck = -25
            b = a; b.ua = 240; b.fa = 170
        case "pull_v":
            a = Pose(hip: CGPoint(x: 44, y: 70), thigh: 90, shin: 180, torso: -8, ua: 6, fa: 4, seat: true)
            b = a; b.torso = -14; b.ua = 165; b.fa = 15
        case "curl":
            b.ua = 174; b.fa = 28
        case "tri_oh":
            a.ua = -4; a.fa = -160; b.ua = -4; b.fa = -4
        case "tri_push":
            a.torso = 8; a.ua = 174; a.fa = 80; b.torso = 8; b.ua = 174; b.fa = 178
        case "raise_l":
            a.ua = 176; a.fa = 178; b.ua = 92; b.fa = 96
        case "calf":
            a.ankle = CGPoint(x: 46, y: 90); a.foot = 96
            b.ankle = CGPoint(x: 46, y: 83); b.foot = 128
        case "leg_curl", "leg_ext":
            a = Pose(hip: CGPoint(x: 38, y: 64), thigh: 90, shin: pattern == "leg_curl" ? 96 : 196, torso: -6, ua: 150, fa: 110, seat: true)
            b = a; b.shin = pattern == "leg_curl" ? 206 : 94
        case "hip_thrust":
            a = Pose(hip: CGPoint(x: 48, y: 84), thigh: 62, shin: 166, torso: -58, ua: 120, fa: 100, bench: true)
            b = Pose(hip: CGPoint(x: 50, y: 72), thigh: 90, shin: 180, torso: -90, ua: 100, fa: 90, bench: true)
        case "core":
            a = Pose(hip: CGPoint(x: 56, y: 86), thigh: 44, shin: 160, torso: -90, ua: 30, fa: 120)
            b = a; b.torso = -55; b.ua = 70; b.fa = 70
        case "face_pull":
            a.torso = -4; a.ua = 88; a.fa = 90
            b.torso = -4; b.ua = -70; b.fa = 15
        case "pullover":
            a.torso = 22; a.ua = 8; a.fa = 8
            b.torso = 22; b.ua = 165; b.fa = 165
        case "adductor", "abductor":
            a = Pose(hip: CGPoint(x: 40, y: 64), thigh: 90, shin: 180, torso: -8, ua: 175, fa: 175, seat: true)
            b = a; b.thigh = pattern == "adductor" ? 70 : 105; b.shin = pattern == "adductor" ? 160 : 195
        case "rear_fly":
            a.shinUp = 14; a.thighUp = -40; a.torso = 70; a.neck = -25; a.ua = 165; a.fa = 165
            b = a; b.ua = 255; b.fa = 250
        default: break
        }
        return (a, b)
    }

    var body: some View {
        TimelineView(.animation(paused: !animated)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let poses = Self.poses(pattern)
            let now = Self.ease(t, animated: animated)
            Canvas { ctx, size in
                let s = size.width / 100
                drawBackground(in: &ctx, size: size, t: t, effort: now)
                // motion afterimages, like anime speed blur
                if animated {
                    for (lag, alpha) in [(0.16, 0.10), (0.08, 0.18)] {
                        draw(Pose.mix(poses.0, poses.1, Self.ease(t - lag, animated: true)), in: &ctx, s: s, ghost: alpha)
                    }
                }
                draw(Pose.mix(poses.0, poses.1, now), in: &ctx, s: s, ghost: nil, effort: now, t: t)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Animazione del movimento")
    }

    /// 2.4 s per rep: slow lowering into the stretch, short pause, faster lift.
    private static func ease(_ t: Double, animated: Bool) -> Double {
        guard animated else { return 1 }
        let phase = (t.truncatingRemainder(dividingBy: 2.4) + 2.4).truncatingRemainder(dividingBy: 2.4) / 2.4
        let raw = phase < 0.5 ? phase / 0.5 : (phase < 0.6 ? 1 : 1 - (phase - 0.6) / 0.4)
        return (1 - cos(raw * .pi)) / 2
    }

    // Palette: cel-shaded anime look.
    private static let skin = Color(red: 1.0, green: 0.84, blue: 0.72)
    private static let skinShade = Color(red: 0.93, green: 0.70, blue: 0.58)
    private static let hair = Color(red: 0.13, green: 0.16, blue: 0.32)
    private static let skinDark = Color(red: 0.78, green: 0.55, blue: 0.45)
    private static let shorts = Color(red: 0.16, green: 0.20, blue: 0.30)
    private static let shortsDark = Color(red: 0.10, green: 0.12, blue: 0.20)
    private static let pump = Color(red: 0.95, green: 0.25, blue: 0.20)
    private static let hairFemale = Color(red: 0.36, green: 0.20, blue: 0.14)
    private static let vein = Color(red: 0.55, green: 0.40, blue: 0.62)
    private static let outline = Color(red: 0.10, green: 0.08, blue: 0.14)

    private func drawBackground(in ctx: inout GraphicsContext, size: CGSize, t: Double, effort: Double) {
        let s = size.width / 100
        let center = CGPoint(x: 50 * s, y: 50 * s)
        // soft spotlight
        ctx.fill(Path(ellipseIn: CGRect(x: 4 * s, y: 4 * s, width: 92 * s, height: 92 * s)),
                 with: .radialGradient(Gradient(colors: [Theme.accent.opacity(0.22), Theme.accent.opacity(0.0)]),
                                       center: center, startRadius: 2 * s, endRadius: 50 * s))
        // radial speed lines that flare at the hardest point of the rep
        if animated {
            let count = 14
            for i in 0..<count {
                let a = Double(i) / Double(count) * 2 * .pi + t * 0.15
                let inner = (38 - effort * 6) * s, outer = 49 * s
                var line = Path()
                line.move(to: CGPoint(x: center.x + cos(a) * inner, y: center.y + sin(a) * inner))
                line.addLine(to: CGPoint(x: center.x + cos(a) * outer, y: center.y + sin(a) * outer))
                ctx.stroke(line, with: .color(Theme.accent.opacity(0.10 + effort * 0.25)), style: StrokeStyle(lineWidth: 1.2 * s, lineCap: .round))
            }
        }
        // floor and contact shadow
        ctx.stroke(Path { $0.move(to: CGPoint(x: 8 * s, y: 92 * s)); $0.addLine(to: CGPoint(x: 92 * s, y: 92 * s)) },
                   with: .color(.secondary.opacity(0.35)), lineWidth: 1.2 * s)
        ctx.fill(Path(ellipseIn: CGRect(x: 26 * s, y: 90 * s, width: 44 * s, height: 4 * s)), with: .color(.black.opacity(0.12)))
    }

    /// One frame of the figure. `ghost` draws a flat afterimage with that opacity.
    private func draw(_ p: Pose, in ctx: inout GraphicsContext, s: CGFloat, ghost: Double?, effort: Double = 0, t: Double = 0) {
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        func add(_ from: CGPoint, _ angle: Double, _ len: Double) -> CGPoint {
            let r = angle * .pi / 180
            return CGPoint(x: from.x + sin(r) * len * s, y: from.y - cos(r) * len * s)
        }
        var ankle: CGPoint, knee: CGPoint, hip: CGPoint
        if let a = p.ankle {
            ankle = pt(a.x, a.y)
            knee = add(ankle, p.shinUp, 18)
            hip = add(knee, p.thighUp, 18)
        } else {
            hip = pt(Double(p.hip?.x ?? 50), Double(p.hip?.y ?? 60))
            knee = add(hip, p.thigh, 18)
            ankle = add(knee, p.shin, 18)
        }
        let shoulder = add(hip, p.torso, 25)
        let elbow = add(shoulder, p.ua, 13)
        let hand = add(elbow, p.fa, 12)
        let toe = add(ankle, p.foot, 6)
        let head = add(shoulder, p.torso + p.neck, 11)

        if let ghost {
            let style = StrokeStyle(lineWidth: 8 * s, lineCap: .round, lineJoin: .round)
            let c = GraphicsContext.Shading.color(Theme.accent.opacity(ghost))
            ctx.stroke(Path { $0.move(to: hip); $0.addLine(to: knee); $0.addLine(to: ankle) }, with: c, style: style)
            ctx.stroke(Path { $0.move(to: hip); $0.addLine(to: shoulder) }, with: c, style: StrokeStyle(lineWidth: 14 * s, lineCap: .round))
            ctx.stroke(Path { $0.move(to: shoulder); $0.addLine(to: elbow); $0.addLine(to: hand) }, with: c, style: style)
            ctx.fill(Path(ellipseIn: CGRect(x: head.x - 7 * s, y: head.y - 7 * s, width: 14 * s, height: 14 * s)), with: c)
            return
        }

        let working = Self.muscles(pattern)
        // women get a toned, athletic body instead of the bodybuilder one
        let female = ProfileStore.shared.profile.sex == .donna
        let bulk: CGFloat = female ? 0.74 : 1
        // the worked muscles "pump" up and glow as the rep gets hard
        let pump = animated ? max(0, (effort - 0.3) / 0.7) : 0.5

        func angle(_ a: CGPoint, _ b: CGPoint) -> CGFloat { atan2(b.x - a.x, -(b.y - a.y)) }
        func unit(_ r: CGFloat) -> CGVector { CGVector(dx: sin(r), dy: -cos(r)) }
        func off(_ p: CGPoint, _ v: CGVector, _ d: CGFloat) -> CGPoint { CGPoint(x: p.x + v.dx * d * s, y: p.y + v.dy * d * s) }
        func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }

        /// Outline of a muscle from `a` to `b`: half-widths at the two ends and at the belly, on side 1
        /// (left of the a→b direction) and side 2.
        func musclePath(_ a: CGPoint, _ b: CGPoint, start: CGFloat, end: CGFloat, belly: CGFloat = 0.45,
                        side1: CGFloat, side2: CGFloat, scale: CGFloat = 1) -> Path {
            let r = angle(a, b)
            let n1 = unit(r + .pi / 2), n2 = unit(r - .pi / 2)
            let m = lerp(a, b, belly)
            let k = scale * bulk
            let a1 = off(a, n1, start * k), b1 = off(b, n1, end * k), m1 = off(m, n1, side1 * k)
            let a2 = off(a, n2, start * k), b2 = off(b, n2, end * k), m2 = off(m, n2, side2 * k)
            func control(_ p: CGPoint, _ q: CGPoint, _ mid: CGPoint) -> CGPoint {
                CGPoint(x: 2 * mid.x - (p.x + q.x) / 2, y: 2 * mid.y - (p.y + q.y) / 2)
            }
            var path = Path()
            path.move(to: a1)
            path.addQuadCurve(to: b1, control: control(a1, b1, m1))
            path.addLine(to: b2)
            path.addQuadCurve(to: a2, control: control(b2, a2, m2))
            path.closeSubpath()
            return path
        }

        /// Cel-shaded muscle: shadow tone, lit core, pump glow when worked, ink outline and a definition line.
        func muscle(_ a: CGPoint, _ b: CGPoint, start: CGFloat, end: CGFloat, belly: CGFloat = 0.45, side1: CGFloat, side2: CGFloat,
                    worked: Bool = false, lit: Color = Self.skin, shade: Color = Self.skinShade, lines: Bool = true) {
            let full = musclePath(a, b, start: start, end: end, belly: belly, side1: side1, side2: side2)
            ctx.fill(full, with: .color(shade))
            ctx.fill(musclePath(a, b, start: start, end: end, belly: belly, side1: side1, side2: side2, scale: 0.6)
                .offsetBy(dx: -0.8 * s, dy: -0.8 * s), with: .color(lit))
            if worked && pump > 0 { ctx.fill(full, with: .color(Self.pump.opacity(0.45 * pump))) }
            ctx.stroke(full, with: .color(Self.outline), style: StrokeStyle(lineWidth: 1.5 * s, lineJoin: .round))
            guard lines else { return }
            let r = angle(a, b)
            let n = unit(r + .pi / 2)
            ctx.stroke(Path {
                $0.move(to: off(lerp(a, b, 0.22), n, side1 * 0.3))
                $0.addQuadCurve(to: off(lerp(a, b, 0.72), n, side1 * 0.25), control: off(lerp(a, b, belly), n, side1 * 0.6))
            }, with: .color(Self.outline.opacity(0.5)), lineWidth: 0.8 * s)
            if worked && pump > 0.4 {
                // striations of a muscle at full contraction
                for k in 0..<3 {
                    let t = 0.35 + CGFloat(k) * 0.12
                    let p = lerp(a, b, t)
                    ctx.stroke(Path { $0.move(to: off(p, n, side1 * 0.15)); $0.addLine(to: off(p, n, side1 * 0.7)) },
                               with: .color(Self.outline.opacity(0.35 * pump)), lineWidth: 0.6 * s)
                }
            }
        }

        func ball(_ p: CGPoint, _ size: CGFloat, worked: Bool = false, lit: Color = Self.skin, shade: Color = Self.skinShade) {
            let r = size * bulk
            let rect = CGRect(x: p.x - r * s, y: p.y - r * s, width: 2 * r * s, height: 2 * r * s)
            ctx.fill(Path(ellipseIn: rect), with: .color(shade))
            ctx.fill(Path(ellipseIn: rect.insetBy(dx: r * 0.3 * s, dy: r * 0.3 * s).offsetBy(dx: -0.6 * s, dy: -0.6 * s)), with: .color(lit))
            if worked && pump > 0 { ctx.fill(Path(ellipseIn: rect), with: .color(Self.pump.opacity(0.45 * pump))) }
            ctx.stroke(Path(ellipseIn: rect), with: .color(Self.outline), lineWidth: 1.5 * s)
        }

        // props
        let metal = Color(red: 0.33, green: 0.35, blue: 0.42)
        if p.bench {
            let bench = Path(roundedRect: CGRect(x: 30 * s, y: 72 * s, width: 50 * s, height: 5 * s), cornerRadius: 2 * s)
            ctx.fill(bench, with: .color(metal))
            ctx.stroke(bench, with: .color(Self.outline), lineWidth: 1.2 * s)
            ctx.fill(Path(CGRect(x: 36 * s, y: 77 * s, width: 2.5 * s, height: 15 * s)), with: .color(Self.outline.opacity(0.7)))
            ctx.fill(Path(CGRect(x: 72 * s, y: 77 * s, width: 2.5 * s, height: 15 * s)), with: .color(Self.outline.opacity(0.7)))
        }
        if p.seat {
            let seat = Path(roundedRect: CGRect(x: 22 * s, y: 68 * s, width: 30 * s, height: 5 * s), cornerRadius: 2 * s)
            ctx.fill(seat, with: .color(metal))
            ctx.stroke(seat, with: .color(Self.outline), lineWidth: 1.2 * s)
            ctx.fill(Path(CGRect(x: 35 * s, y: 73 * s, width: 3 * s, height: 19 * s)), with: .color(Self.outline.opacity(0.7)))
        }

        let torsoAngle = angle(hip, shoulder)
        let front = unit(torsoAngle + .pi / 2), back = unit(torsoAngle - .pi / 2)

        // far leg, in shadow
        if let leg2 = p.leg2 {
            let k2 = add(hip, leg2.0, 18), a2 = add(k2, leg2.1, 18)
            muscle(hip, k2, start: 4.6, end: 3, side1: 4.2, side2: 4.8, lit: Self.skinShade, shade: Self.skinDark, lines: false)
            muscle(k2, a2, start: 2.8, end: 1.8, belly: 0.3, side1: 3.4, side2: 2.2, lit: Self.skinShade, shade: Self.skinDark, lines: false)
        }

        // glutes behind the hip
        ball(off(hip, back, 3.2), 5.2, worked: working.contains(.glutes), lit: Self.shorts, shade: Self.shortsDark)

        // torso: V shape, big chest in front and lats behind
        muscle(hip, shoulder, start: 4.4, end: 5.4, belly: 0.72, side1: 7.6, side2: 7.4,
               worked: false, lines: false)
        if working.contains(.chest) || working.contains(.back) {
            let upper = lerp(hip, shoulder, 0.5)
            let region = musclePath(upper, shoulder, start: 0.5, end: 1, belly: 0.5,
                                    side1: working.contains(.chest) ? 7.4 : 0.5, side2: working.contains(.back) ? 7.2 : 0.5)
            ctx.fill(region, with: .color(Self.pump.opacity(0.4 * pump)))
        }
        if female {
            // sports top over the chest
            let top = musclePath(lerp(hip, shoulder, 0.55), lerp(hip, shoulder, 0.98), start: 6.4, end: 5.6, belly: 0.4, side1: 7.8, side2: 7.4)
            ctx.fill(top, with: .color(Theme.accent))
            ctx.stroke(top, with: .color(Self.outline), lineWidth: 1.3 * s)
        }
        // pec line, abs, lats
        let pecStart = off(lerp(hip, shoulder, 0.62), front, 7.2)
        ctx.stroke(Path {
            $0.move(to: pecStart)
            $0.addQuadCurve(to: off(lerp(hip, shoulder, 0.9), front, 1.5), control: off(lerp(hip, shoulder, 0.66), front, 2.5))
        }, with: .color(Self.outline.opacity(0.7)), lineWidth: 1.1 * s)
        for (i, t) in [0.16, 0.29, 0.42].enumerated() {
            let width = 4.4 + (7.6 - 4.4) * CGFloat(t) / 0.72
            let p0 = lerp(hip, shoulder, CGFloat(t))
            ctx.stroke(Path { $0.move(to: off(p0, front, width - 0.6)); $0.addLine(to: off(p0, front, width - 3.6)) },
                       with: .color(Self.outline.opacity(working.contains(.abs) ? 0.8 : 0.45)), lineWidth: (i == 0 ? 0.8 : 0.9) * s)
        }
        ctx.stroke(Path {
            $0.move(to: off(lerp(hip, shoulder, 0.1), front, 2.6))
            $0.addLine(to: off(lerp(hip, shoulder, 0.55), front, 4.4))
        }, with: .color(Self.outline.opacity(0.45)), lineWidth: 0.8 * s)
        ctx.stroke(Path {
            $0.move(to: off(lerp(hip, shoulder, 0.35), back, 4.8))
            $0.addQuadCurve(to: off(lerp(hip, shoulder, 0.85), back, 4.5), control: off(lerp(hip, shoulder, 0.62), back, 3.0))
        }, with: .color(Self.outline.opacity(0.55)), lineWidth: 0.9 * s)
        if working.contains(.abs) && pump > 0 {
            ctx.fill(musclePath(lerp(hip, shoulder, 0.08), lerp(hip, shoulder, 0.55), start: 0.5, end: 0.5, belly: 0.5, side1: 6.4, side2: 0.2),
                     with: .color(Self.pump.opacity(0.4 * pump)))
        }

        // near leg: quads in front, hamstrings behind, big calf, shorts and shoe
        muscle(hip, knee, start: 5.4, end: 3.2, belly: 0.4, side1: 4.6, side2: 5.6,
               worked: !working.isDisjoint(with: [.quads, .hamstrings]))
        muscle(hip, lerp(hip, knee, 0.5), start: 5.8, end: 5.4, belly: 0.5, side1: 5.6, side2: 6.2, lit: Self.shorts, shade: Self.shortsDark, lines: false)
        muscle(knee, ankle, start: 3, end: 1.8, belly: 0.3, side1: 4.2, side2: 2.4, worked: working.contains(.calves))
        let shoe = musclePath(ankle, toe, start: 2.2, end: 1.6, belly: 0.5, side1: 2.4, side2: 2.2)
        ctx.fill(shoe, with: .color(.white))
        ctx.stroke(shoe, with: .color(Self.outline), lineWidth: 1.3 * s)

        // thick neck and traps
        let neckTop = lerp(shoulder, head, 0.55)
        var traps = Path()
        traps.move(to: off(neckTop, back, 2.6))
        traps.addQuadCurve(to: off(shoulder, back, 6.8), control: off(lerp(shoulder, neckTop, 0.2), back, 6.5))
        traps.addLine(to: off(shoulder, front, 3))
        traps.closeSubpath()
        ctx.fill(traps, with: .color(Self.skinShade))
        ctx.stroke(traps, with: .color(Self.outline), lineWidth: 1.3 * s)
        muscle(shoulder, neckTop, start: 3.6, end: 3, belly: 0.5, side1: 3.4, side2: 3.8, lines: false)

        // head: small next to the body, square jaw, fierce eye, spiky hair
        let r: CGFloat = 5.8 * s
        let face = CGFloat((p.torso + p.neck) * .pi / 180)
        let eyeDir = face + .pi / 2
        let headRect = CGRect(x: head.x - r, y: head.y - r, width: 2 * r, height: 2 * r)
        if female {
            // ponytail swinging behind the head
            let backDir = face - .pi / 2
            let base = CGPoint(x: head.x + sin(backDir) * r * 0.9, y: head.y - cos(backDir) * r * 0.9 - r * 0.2)
            var tail = Path()
            tail.move(to: base)
            tail.addQuadCurve(to: CGPoint(x: base.x + sin(backDir) * r * 1.4, y: base.y + r * 1.9),
                              control: CGPoint(x: base.x + sin(backDir) * r * 1.9, y: base.y + r * 0.2))
            tail.addQuadCurve(to: CGPoint(x: base.x, y: base.y + r * 0.5),
                              control: CGPoint(x: base.x + sin(backDir) * r * 0.6, y: base.y + r * 1.2))
            tail.closeSubpath()
            ctx.fill(tail, with: .color(Self.hairFemale))
            ctx.stroke(tail, with: .color(Self.outline), lineWidth: 1 * s)
        }
        var jaw = Path()
        let chin = CGPoint(x: head.x + sin(eyeDir) * r * 0.75 + sin(face + .pi) * r * 0.85, y: head.y - cos(eyeDir) * r * 0.75 - cos(face + .pi) * r * 0.85)
        jaw.move(to: CGPoint(x: head.x + sin(eyeDir) * r, y: head.y - cos(eyeDir) * r))
        jaw.addLine(to: chin)
        jaw.addLine(to: CGPoint(x: head.x + sin(face + .pi) * r, y: head.y - cos(face + .pi) * r))
        jaw.closeSubpath()
        if !female {
            ctx.fill(jaw, with: .color(Self.skin))
            ctx.stroke(jaw, with: .color(Self.outline), lineWidth: 1.3 * s)
        }
        ctx.fill(Path(ellipseIn: headRect), with: .color(Self.skin))
        ctx.stroke(Path(ellipseIn: headRect), with: .color(Self.outline), lineWidth: 1.4 * s)
        var hair = Path()
        for i in 0..<7 {
            let a = face - 2.0 + CGFloat(i) * 0.5
            let base1 = CGPoint(x: head.x + sin(a - 0.28) * r, y: head.y - cos(a - 0.28) * r)
            let base2 = CGPoint(x: head.x + sin(a + 0.28) * r, y: head.y - cos(a + 0.28) * r)
            let spike = r * (i == 2 || i == 3 ? 2.2 : 1.75)
            let tip = CGPoint(x: head.x + sin(a - 0.5) * spike, y: head.y - cos(a - 0.5) * spike)
            hair.move(to: base1); hair.addLine(to: tip); hair.addLine(to: base2)
            hair.addQuadCurve(to: base1, control: head)
        }
        hair.addArc(center: head, radius: r * 1.02, startAngle: .radians(Double(face) - .pi * 1.05), endAngle: .radians(Double(face) - .pi * 0.05), clockwise: false)
        ctx.fill(hair, with: .color(female ? Self.hairFemale : Self.hair))
        ctx.stroke(hair, with: .color(Self.outline), lineWidth: 0.8 * s)
        // fierce eye under a heavy brow
        let eye = CGPoint(x: head.x + sin(eyeDir) * r * 0.5, y: head.y - cos(eyeDir) * r * 0.5)
        var eyeShape = Path()
        eyeShape.move(to: CGPoint(x: eye.x - 1.8 * s, y: eye.y))
        eyeShape.addQuadCurve(to: CGPoint(x: eye.x + 1.8 * s, y: eye.y - 0.4 * s), control: CGPoint(x: eye.x, y: eye.y - 1.6 * s))
        eyeShape.addQuadCurve(to: CGPoint(x: eye.x - 1.8 * s, y: eye.y), control: CGPoint(x: eye.x, y: eye.y + 1.0 * s))
        ctx.fill(eyeShape, with: .color(.white))
        ctx.fill(Path(ellipseIn: CGRect(x: eye.x - 0.5 * s, y: eye.y - 0.9 * s, width: 1.1 * s, height: 1.3 * s)), with: .color(Self.outline))
        ctx.stroke(eyeShape, with: .color(Self.outline), lineWidth: 0.7 * s)
        ctx.stroke(Path {
            $0.move(to: CGPoint(x: eye.x - 2.4 * s, y: eye.y - 2.4 * s))
            $0.addLine(to: CGPoint(x: eye.x + 2.2 * s, y: eye.y - 1.4 * s))
        }, with: .color(Self.outline), style: StrokeStyle(lineWidth: 1.4 * s, lineCap: .round))
        if effort > 0.6 {
            // gritted teeth at the hardest point
            let mouth = CGPoint(x: head.x + sin(eyeDir) * r * 0.55 + sin(face + .pi) * r * 0.55, y: head.y - cos(eyeDir) * r * 0.55 - cos(face + .pi) * r * 0.55)
            ctx.fill(Path(CGRect(x: mouth.x - 1.2 * s, y: mouth.y - 0.5 * s, width: 2.4 * s, height: 1.0 * s)), with: .color(.white))
            ctx.stroke(Path(CGRect(x: mouth.x - 1.2 * s, y: mouth.y - 0.5 * s, width: 2.4 * s, height: 1.0 * s)), with: .color(Self.outline), lineWidth: 0.5 * s)
        }

        // working arm: round deltoid, biceps and triceps, veiny forearm
        if working.contains(.shoulders) || working.contains(.biceps) || working.contains(.triceps) || working.contains(.back) {
            var glow = ctx
            glow.addFilter(.blur(radius: 3 * s))
            glow.stroke(Path { $0.move(to: shoulder); $0.addLine(to: elbow); $0.addLine(to: hand) },
                        with: .color(Self.pump.opacity(0.35 * pump)), style: StrokeStyle(lineWidth: 12 * s, lineCap: .round, lineJoin: .round))
        }
        muscle(shoulder, elbow, start: 3.8, end: 2.4, belly: 0.45, side1: 3.6, side2: 4.0,
               worked: !working.isDisjoint(with: [.biceps, .triceps]))
        muscle(elbow, hand, start: 2.8, end: 1.6, belly: 0.3, side1: 3.0, side2: 2.6, worked: false)
        // forearm vein
        let fn = unit(angle(elbow, hand) + .pi / 2)
        if !female { ctx.stroke(Path {
            $0.move(to: off(lerp(elbow, hand, 0.2), fn, 0.6))
            $0.addQuadCurve(to: off(lerp(elbow, hand, 0.75), fn, -0.4), control: off(lerp(elbow, hand, 0.5), fn, 1.6))
        }, with: .color(Self.vein.opacity(0.8)), lineWidth: 0.7 * s) }
        ball(off(shoulder, back, 0.6), 4.8, worked: working.contains(.shoulders))
        // dumbbell across the hand
        let bar = Path { $0.move(to: CGPoint(x: hand.x - 4.8 * s, y: hand.y)); $0.addLine(to: CGPoint(x: hand.x + 4.8 * s, y: hand.y)) }
        ctx.stroke(bar, with: .color(Self.outline), style: StrokeStyle(lineWidth: 2 * s, lineCap: .round))
        for dx in [-4.8, 4.8] {
            let plate = Path(roundedRect: CGRect(x: hand.x + CGFloat(dx) * s - 1.7 * s, y: hand.y - 3.9 * s, width: 3.4 * s, height: 7.8 * s), cornerRadius: 1 * s)
            ctx.fill(plate, with: .color(metal))
            ctx.stroke(plate, with: .color(Self.outline), lineWidth: 0.8 * s)
        }
        ball(hand, 2.4)

        // impact sparks and a sweat drop at the hardest point of the rep
        if animated && effort > 0.85 {
            let k = (effort - 0.85) / 0.15
            for i in 0..<6 {
                let a = Double(i) / 6 * 2 * .pi + 0.3
                let from = CGPoint(x: hand.x + cos(a) * 6.5 * s, y: hand.y + sin(a) * 6.5 * s)
                let to = CGPoint(x: hand.x + cos(a) * (6.5 + 5 * k) * s, y: hand.y + sin(a) * (6.5 + 5 * k) * s)
                ctx.stroke(Path { $0.move(to: from); $0.addLine(to: to) }, with: .color(.yellow.opacity(k)), style: StrokeStyle(lineWidth: 1.3 * s, lineCap: .round))
            }
            let drop = CGPoint(x: head.x - sin(eyeDir) * r * 1.2, y: head.y - r * 0.4 + k * 3 * s)
            var tear = Path()
            tear.move(to: CGPoint(x: drop.x, y: drop.y - 2.4 * s))
            tear.addQuadCurve(to: CGPoint(x: drop.x, y: drop.y + 1.6 * s), control: CGPoint(x: drop.x + 2.6 * s, y: drop.y + 1 * s))
            tear.addQuadCurve(to: CGPoint(x: drop.x, y: drop.y - 2.4 * s), control: CGPoint(x: drop.x - 2.6 * s, y: drop.y + 1 * s))
            ctx.fill(tear, with: .color(.cyan.opacity(0.85 * k)))
        }
    }

    enum Muscle: Hashable { case chest, back, shoulders, biceps, triceps, quads, hamstrings, glutes, calves, abs }

    /// Muscles trained by each movement, highlighted in the animation.
    static func muscles(_ pattern: String) -> Set<Muscle> {
        switch pattern {
        case "push_h", "fly": [.chest, .triceps, .shoulders]
        case "push_v": [.shoulders, .triceps]
        case "raise_l", "rear_fly", "face_pull": [.shoulders]
        case "pull_v", "pull_h": [.back, .biceps]
        case "pullover": [.back]
        case "adductor": [.quads]
        case "abductor": [.glutes]
        case "curl": [.biceps]
        case "tri_oh", "tri_push": [.triceps]
        case "squat", "lunge", "leg_ext": [.quads, .glutes]
        case "hinge", "leg_curl": [.hamstrings, .glutes]
        case "hip_thrust": [.glutes, .hamstrings]
        case "calf": [.calves]
        case "core": [.abs]
        default: []
        }
    }
}
