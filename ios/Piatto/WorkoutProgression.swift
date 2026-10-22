import Foundation

/// Progression by month of the cycle, as in the user's Google Calendar plan:
///   month 1 → the plan's sets and reps, +1 rep or +2.5 kg a week
///   month 2 → tempo 3-1-1-0, loads −10%; fundamentals 4×8–10, complementary 3×12–15, isolation 3×15
///   month 3 → fundamentals 4×6–8 + rest-pause, complementary 3×10–12, isolation 3×12–15, double dropsets, RIR 0
///   deload weeks → 60% load, fundamentals 3×8, complementary 2×10, isolation 2×12, no dropsets, never to failure
enum Progression {
    enum Phase: Equatable {
        case month(Int), deload, finished

        var title: String {
            switch self {
            case .month(1): "Mese 1 · serie base, +1 ripetizione o +2,5 kg a settimana"
            case .month(2): "Mese 2 · tempo 3-1-1-0, carichi −10%"
            case .month(3): "Mese 3 · intensificatori: rest-pause e dropset doppi"
            case .month(let n): "Mese \(n)"
            case .deload: "Settimana di scarico · carico al 60%, mai a cedimento"
            case .finished: "Ciclo finito · aggiorna la scheda dal Calendario"
            }
        }
    }

    static func phase(on date: Date = .now, cycle: Cycle = PlanStore.shared.cycle) -> Phase {
        let day = Calendar.current.startOfDay(for: date)
        if cycle.deloads.contains(where: { $0.contains(day) }) { return .deload }
        if day <= cycle.month1End { return .month(1) }
        if cycle.month2.contains(day) { return .month(2) }
        if cycle.month3.contains(day) { return .month(3) }
        return day > cycle.month3.upperBound ? .finished : .month(1)
    }

    static func title(_ phase: Phase = phase()) -> String { phase.title }

    /// The exercise as it should be done in this phase.
    static func apply(_ exercise: Exercise, phase: Phase) -> Exercise {
        var e = exercise
        switch (phase, exercise.role) {
        case (.month(2), .fondamentale): e.sets = 4; e.reps = "8–10"
        case (.month(2), .complementare): e.sets = 3; e.reps = "12–15"
        case (.month(2), .isolamento): e.sets = 3; e.reps = "15"
        case (.month(3), .fondamentale): e.sets = 4; e.reps = "6–8"; e.rir = "0"
        case (.month(3), .complementare): e.sets = 3; e.reps = "10–12"; e.rir = "0–1"
        case (.month(3), .isolamento): e.sets = 3; e.reps = "12–15"; e.rir = "0"
        case (.deload, .fondamentale): e.sets = 3; e.reps = "8"; e.rir = "3+"
        case (.deload, .complementare): e.sets = 2; e.reps = "10"; e.rir = "3+"
        case (.deload, .isolamento): e.sets = 2; e.reps = "12"; e.rir = "3+"
        default: break
        }
        if phase == .deload { e.dropset = nil }
        if phase == .month(3), let d = e.dropset { e.dropset = d + " doppio" }
        return e
    }

    /// What changes this month for this exercise.
    static func note(_ exercise: Exercise, phase: Phase) -> String? {
        var parts: [String] = []
        switch phase {
        case .month(1): break
        case .month(2): parts.append("Tempo 3-1-1-0: 3 s a scendere, 1 s di pausa in basso, 1 s a salire. Carico −10% rispetto al mese 1.")
            if exercise.role == .isolamento { parts.append("Eccentrica di 3 s.") }
        case .month(3):
            if exercise.role == .fondamentale { parts.append("Ultima serie in rest-pause: 15 s di pausa e altre ripetizioni.") }
            if exercise.dropset != nil { parts.append("Dropset doppio: cedimento → −25% → cedimento → −25% → cedimento.") }
        case .deload: parts.append("Scarico: 60% del carico solito, niente dropset né tempo lento, mai a cedimento. Non segnare record.")
        case .finished: parts.append("Il ciclo è finito: aggiorna la scheda dal Calendario quando hai quella nuova.")
        case .month: break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Roles for a plan written without them: the first pair is fundamental, single-joint moves are isolation.
    static func withRoles(_ days: [WorkoutDay]) -> [WorkoutDay] {
        days.map { day in
            var day = day
            for b in day.blocks.indices {
                for e in day.blocks[b].exercises.indices {
                    let ex = day.blocks[b].exercises[e]
                    day.blocks[b].exercises[e].role = b == 0 ? .fondamentale : PlanParser.isCompound(ex.name) ? .complementare : .isolamento
                }
            }
            return day
        }
    }
}

/// Alternatives for each movement pattern, for when a machine is busy. Same muscles, same animation pattern.
enum ExerciseSwaps {
    struct Option: Hashable {
        var name: String
        var pattern: String
        var cue: String
    }

    static let options: [String: [Option]] = [
        "push_h": [
            Option(name: "Panca piana con bilanciere", pattern: "push_h", cue: "Piedi a terra, scapole addotte, bilanciere al centro del petto."),
            Option(name: "Chest press convergente (Hammer)", pattern: "push_h", cue: "Spingi le maniglie verso il centro, petto alto."),
            Option(name: "Panca inclinata con manubri", pattern: "push_h", cue: "Panca a 30°, scendi con i manubri ai lati del petto."),
            Option(name: "Dip alle parallele (busto avanti)", pattern: "push_h", cue: "Busto inclinato in avanti, scendi finché le spalle sono sotto i gomiti."),
            Option(name: "Panca piana con manubri", pattern: "push_h", cue: "Scapole strette, scendi fino al petto."),
            Option(name: "Chest press alla macchina", pattern: "push_h", cue: "Maniglie all'altezza del petto, spingi senza bloccare i gomiti."),
            Option(name: "Panca inclinata al multipower", pattern: "push_h", cue: "Panca a 30°, bilanciere sulla parte alta del petto."),
            Option(name: "Piegamenti sulle braccia", pattern: "push_h", cue: "Corpo rigido, petto fino a terra; zavorra se troppo facili."),
        ],
        "fly": [
            Option(name: "Croci ai cavi dal basso", pattern: "fly", cue: "Cavi in basso, porta le mani verso l'alto davanti al petto."),
            Option(name: "Croci su panca inclinata", pattern: "fly", cue: "Panca a 30°, apri finché senti il petto allungarsi."),
            Option(name: "Svend press", pattern: "fly", cue: "Disco stretto tra i palmi, spingi in avanti stringendo il petto."),
            Option(name: "Croci ai cavi", pattern: "fly", cue: "Cavi all'altezza delle spalle, apri ad arco con gomiti morbidi."),
            Option(name: "Pec deck", pattern: "fly", cue: "Lascia aprire le braccia fino a sentire il petto allungarsi."),
            Option(name: "Croci con manubri su panca", pattern: "fly", cue: "Gomiti leggermente piegati e fissi."),
        ],
        "pull_v": [
            Option(name: "Trazioni alla sbarra", pattern: "pull_v", cue: "Parti a braccia distese, petto verso la sbarra."),
            Option(name: "Lat machine presa inversa", pattern: "pull_v", cue: "Palmi verso di te, gomiti lungo i fianchi."),
            Option(name: "Pulldown a braccia tese al cavo", pattern: "pullover", cue: "Braccia quasi tese, porta la barra alle cosce."),
            Option(name: "Lat pulldown presa larga", pattern: "pull_v", cue: "Petto alto, porta la barra al petto."),
            Option(name: "Lat machine presa neutra", pattern: "pull_v", cue: "Gomiti verso i fianchi."),
            Option(name: "Trazioni assistite", pattern: "pull_v", cue: "Braccia distese in basso a ogni ripetizione."),
            Option(name: "Lat machine monolaterale", pattern: "pull_v", cue: "Un braccio alla volta, allunga bene in alto."),
        ],
        "pull_h": [
            Option(name: "T-bar row", pattern: "pull_h", cue: "Petto alto, tira la maniglia verso lo sterno."),
            Option(name: "Rematore al multipower", pattern: "pull_h", cue: "Busto a 45°, tira verso l'ombelico."),
            Option(name: "Rematore su panca inclinata con manubri", pattern: "pull_h", cue: "Petto sulla panca, gomiti indietro."),
            Option(name: "Low row alla macchina (Hammer)", pattern: "pull_h", cue: "Un braccio o due, gomiti vicini al corpo."),
            Option(name: "Rematore monolaterale al cavo", pattern: "pull_h", cue: "Un braccio alla volta, gomito verso l'anca."),
            Option(name: "Pulley basso", pattern: "pull_h", cue: "Busto fermo, maniglia all'ombelico."),
            Option(name: "Rematore con manubrio", pattern: "pull_h", cue: "Gomito verso l'anca."),
            Option(name: "Rematore alla macchina con appoggio al petto", pattern: "pull_h", cue: "Petto sull'appoggio, niente slancio."),
            Option(name: "Rematore con bilanciere", pattern: "pull_h", cue: "Busto a 45°, schiena neutra."),
        ],
        "face_pull": [
            Option(name: "Face pull con elastico", pattern: "face_pull", cue: "Tira verso la fronte aprendo i gomiti."),
            Option(name: "Face pull al cavo", pattern: "face_pull", cue: "Corda verso la fronte, gomiti alti."),
            Option(name: "Reverse pec deck", pattern: "rear_fly", cue: "Apri le braccia indietro, petto sul cuscino."),
            Option(name: "Alzate posteriori al cavo", pattern: "rear_fly", cue: "Busto inclinato, apri le braccia indietro."),
        ],
        "rear_fly": [
            Option(name: "Alzate posteriori su panca inclinata", pattern: "rear_fly", cue: "Petto sulla panca, apri le braccia."),
            Option(name: "Alzate posteriori al cavo", pattern: "rear_fly", cue: "Busto inclinato, apri le braccia indietro."),
            Option(name: "Reverse pec deck", pattern: "rear_fly", cue: "Apri le braccia indietro, petto sul cuscino."),
            Option(name: "Alzate posteriori con manubri", pattern: "rear_fly", cue: "Busto parallelo al pavimento, gomiti morbidi."),
            Option(name: "Face pull al cavo", pattern: "face_pull", cue: "Corda verso la fronte, gomiti alti."),
        ],
        "push_v": [
            Option(name: "Lento avanti al multipower", pattern: "push_v", cue: "Seduto, bilanciere davanti al viso fino al mento."),
            Option(name: "Landmine press", pattern: "push_v", cue: "Spingi il bilanciere in alto e in avanti con un braccio."),
            Option(name: "Shoulder press con manubri in piedi", pattern: "push_v", cue: "Addome contratto, niente inarcamento."),
            Option(name: "Shoulder press alla macchina", pattern: "push_v", cue: "Schiena appoggiata, scendi sotto il mento."),
            Option(name: "Lento avanti con manubri", pattern: "push_v", cue: "Glutei contratti, spingi dritto."),
            Option(name: "Arnold press", pattern: "push_v", cue: "Ruota i palmi mentre sali."),
        ],
        "squat": [
            Option(name: "Pendulum squat", pattern: "squat", cue: "Scendi profondo, ginocchia in avanti."),
            Option(name: "Front squat", pattern: "squat", cue: "Gomiti alti, busto dritto."),
            Option(name: "Belt squat", pattern: "squat", cue: "Busto eretto, scendi sotto il parallelo."),
            Option(name: "Leg press", pattern: "squat", cue: "Scendi finché il bacino non si stacca dallo schienale."),
            Option(name: "Hack squat", pattern: "squat", cue: "Piedi a metà pedana, scendi profondo."),
            Option(name: "Goblet squat", pattern: "squat", cue: "Manubrio al petto, gomiti tra le ginocchia."),
            Option(name: "Squat al multipower", pattern: "squat", cue: "Piedi leggermente avanti, scendi sotto il parallelo."),
        ],
        "hinge": [
            Option(name: "Stacco rumeno con bilanciere", pattern: "hinge", cue: "Bilanciere vicino alle gambe, anche indietro."),
            Option(name: "Stacco a gambe tese con manubri", pattern: "hinge", cue: "Ginocchia quasi tese, schiena neutra."),
            Option(name: "Reverse hyperextension", pattern: "hinge", cue: "Busto sul cuscino, solleva le gambe con i glutei."),
            Option(name: "Kettlebell swing", pattern: "hinge", cue: "Spinta esplosiva delle anche, braccia rilassate."),
            Option(name: "Stacco rumeno con manubri", pattern: "hinge", cue: "Anche indietro, manubri vicini alle gambe."),
            Option(name: "Good morning", pattern: "hinge", cue: "Bilanciere sulle spalle, ginocchia morbide."),
            Option(name: "Hyperextension 45°", pattern: "hinge", cue: "Muovi le anche, non la schiena."),
            Option(name: "Pull-through al cavo", pattern: "hinge", cue: "Corda tra le gambe, spingi le anche in avanti."),
        ],
        "lunge": [
            Option(name: "Split squat bulgaro", pattern: "lunge", cue: "Piede dietro su panca, scendi in verticale."),
            Option(name: "Affondi indietro con manubri", pattern: "lunge", cue: "Passo indietro, ginocchio vicino a terra."),
            Option(name: "Affondi alla Smith machine", pattern: "lunge", cue: "Passo lungo, busto leggermente in avanti per i glutei."),
            Option(name: "Affondi in camminata", pattern: "lunge", cue: "Passo lungo, ginocchio dietro vicino a terra."),
            Option(name: "Step-up su panca", pattern: "lunge", cue: "Spingi con la gamba sopra, non con quella a terra."),
            Option(name: "Split squat al multipower", pattern: "lunge", cue: "Busto dritto, scendi in verticale."),
        ],
        "leg_curl": [
            Option(name: "Leg curl in piedi monolaterale", pattern: "leg_curl", cue: "Una gamba alla volta, bacino fermo."),
            Option(name: "Leg curl con fitball", pattern: "leg_curl", cue: "Bacino alto, porta i talloni verso i glutei."),
            Option(name: "Glute ham raise", pattern: "leg_curl", cue: "Scendi controllato, risali con i femorali."),
            Option(name: "Leg curl da seduto", pattern: "leg_curl", cue: "Busto in avanti."),
            Option(name: "Leg curl sdraiato", pattern: "leg_curl", cue: "Bacino premuto sulla panca."),
            Option(name: "Nordic curl assistito", pattern: "leg_curl", cue: "Scendi lento, aiutati con le mani."),
        ],
        "leg_ext": [
            Option(name: "Spanish squat con elastico", pattern: "squat", cue: "Elastico dietro le ginocchia, busto dritto."),
            Option(name: "Leg extension", pattern: "leg_ext", cue: "Sali fino quasi a distendere."),
            Option(name: "Leg extension monolaterale", pattern: "leg_ext", cue: "Una gamba alla volta, pausa in alto."),
            Option(name: "Sissy squat assistito", pattern: "squat", cue: "Ginocchia avanti, tieniti a un appoggio."),
        ],
        "calf": [
            Option(name: "Calf al multipower", pattern: "calf", cue: "Punte su un rialzo, discesa completa."),
            Option(name: "Calf monolaterale con manubrio", pattern: "calf", cue: "Un piede alla volta su un gradino."),
            Option(name: "Calf raise in piedi", pattern: "calf", cue: "Pausa con il tallone in basso."),
            Option(name: "Calf alla leg press", pattern: "calf", cue: "Solo le punte sulla pedana."),
            Option(name: "Calf seduto", pattern: "calf", cue: "Ritmo lento, niente rimbalzi."),
        ],
        "hip_thrust": [
            Option(name: "Hip thrust monolaterale", pattern: "hip_thrust", cue: "Una gamba alla volta, bacino dritto."),
            Option(name: "Hip thrust al multipower", pattern: "hip_thrust", cue: "Bilanciere guidato sul bacino, spingi con i talloni."),
            Option(name: "Kickback al cavo", pattern: "hip_thrust", cue: "Cavigliera al cavo basso, spingi la gamba indietro."),
            Option(name: "Glute bridge a terra", pattern: "hip_thrust", cue: "Schiena a terra, stringi in alto 2 s."),
            Option(name: "Hip thrust", pattern: "hip_thrust", cue: "Mento in basso, spingi con i talloni."),
            Option(name: "Hip thrust alla macchina", pattern: "hip_thrust", cue: "1 s di stretta in alto."),
            Option(name: "Glute bridge con bilanciere", pattern: "hip_thrust", cue: "Schiena a terra, spingi il bacino in alto."),
        ],
        "pullover": [
            Option(name: "Pullover al cavo", pattern: "pullover", cue: "Braccia quasi tese, porta la barra alle cosce."),
            Option(name: "Pullover con manubrio", pattern: "pullover", cue: "Sdraiato, porta il manubrio dietro la testa."),
            Option(name: "Pulldown a braccia tese con corda", pattern: "pullover", cue: "Corda al cavo alto, spingi verso le cosce."),
            Option(name: "Pullover alla macchina", pattern: "pullover", cue: "Gomiti sui cuscinetti, porta le braccia in basso."),
        ],
        "adductor": [
            Option(name: "Adductor machine", pattern: "adductor", cue: "Chiudi le gambe lentamente, 1 s di stretta."),
            Option(name: "Adduzioni al cavo", pattern: "adductor", cue: "Cavigliera al cavo basso, porta la gamba verso l'altra."),
            Option(name: "Copenhagen plank", pattern: "adductor", cue: "Gamba sopra su una panca, solleva il bacino."),
            Option(name: "Squat sumo con manubrio", pattern: "squat", cue: "Piedi larghi e punte fuori, scendi profondo."),
        ],
        "abductor": [
            Option(name: "Abductor machine", pattern: "abductor", cue: "Busto in avanti per i glutei, apri lento."),
            Option(name: "Abduzioni al cavo", pattern: "abductor", cue: "Cavigliera al cavo basso, apri la gamba di lato."),
            Option(name: "Camminata laterale con elastico", pattern: "abductor", cue: "Elastico sopra le ginocchia, passi laterali in semi-squat."),
            Option(name: "Abduzioni da sdraiato su un fianco", pattern: "abductor", cue: "Gamba tesa, sali senza ruotare il bacino."),
        ],
        "core": [
            Option(name: "Leg raise a terra", pattern: "core", cue: "Schiena incollata a terra, scendi lento."),
            Option(name: "Pallof press", pattern: "core", cue: "Cavo laterale, spingi avanti senza ruotare."),
            Option(name: "Crunch alla macchina", pattern: "core", cue: "Arrotola il busto, non tirare con le braccia."),
            Option(name: "Crunch al cavo", pattern: "core", cue: "Arrotola la colonna."),
            Option(name: "Plank", pattern: "core", cue: "Glutei contratti, 30–60 s."),
            Option(name: "Ab wheel", pattern: "core", cue: "Bacino in retroversione, non inarcare."),
            Option(name: "Knee raise alla sbarra", pattern: "core", cue: "Porta le ginocchia al petto senza dondolare."),
        ],
        "curl": [
            Option(name: "Curl con bilanciere EZ", pattern: "curl", cue: "Gomiti fermi, scendi completamente."),
            Option(name: "Curl Bayesian al cavo", pattern: "curl", cue: "Cavo alle spalle, gomito dietro al busto."),
            Option(name: "Curl alla panca Scott", pattern: "curl", cue: "Braccio sul cuscino, distendi in basso."),
            Option(name: "Curl con corda al cavo", pattern: "curl", cue: "Presa a martello, gomiti fermi."),
            Option(name: "Curl con manubri", pattern: "curl", cue: "Gomiti fermi ai fianchi."),
            Option(name: "Curl al cavo", pattern: "curl", cue: "Tensione costante, scendi completamente."),
            Option(name: "Curl a martello", pattern: "curl", cue: "Palmi uno verso l'altro."),
            Option(name: "Curl su panca inclinata", pattern: "curl", cue: "Braccia dietro il busto."),
        ],
        "tri_oh": [
            Option(name: "French press con bilanciere EZ", pattern: "tri_oh", cue: "Sdraiato, porta il bilanciere dietro la testa."),
            Option(name: "Estensioni monomanubrio dietro la testa", pattern: "tri_oh", cue: "Un braccio alla volta, gomito verso il soffitto."),
            Option(name: "Estensioni sopra la testa con corda", pattern: "tri_oh", cue: "Di spalle al cavo, distendi le braccia in avanti."),
            Option(name: "Estensioni tricipiti sopra la testa al cavo", pattern: "tri_oh", cue: "Gomiti vicini alla testa."),
            Option(name: "French press con manubrio", pattern: "tri_oh", cue: "Manubrio dietro la testa, gomiti fermi."),
        ],
        "tri_push": [
            Option(name: "Push-down monolaterale al cavo", pattern: "tri_push", cue: "Un braccio alla volta, gomito fermo."),
            Option(name: "Dip su panca", pattern: "tri_push", cue: "Mani sulla panca dietro di te, scendi a 90°."),
            Option(name: "Panca presa stretta", pattern: "tri_push", cue: "Mani alla larghezza delle spalle, gomiti vicini."),
            Option(name: "Push-down al cavo", pattern: "tri_push", cue: "Gomiti fermi ai fianchi."),
            Option(name: "Push-down con corda", pattern: "tri_push", cue: "Apri la corda in basso."),
            Option(name: "Dip alla macchina", pattern: "tri_push", cue: "Busto dritto, gomiti indietro."),
        ],
        "raise_l": [
            Option(name: "Alzate laterali monolaterali al cavo", pattern: "raise_l", cue: "Un braccio alla volta, cavo dietro il corpo."),
            Option(name: "Alzate laterali su panca inclinata", pattern: "raise_l", cue: "Fianco sulla panca, sali fino all'orizzontale."),
            Option(name: "Tirate al mento larghe al cavo", pattern: "raise_l", cue: "Presa larga, gomiti guidano fino alle spalle."),
            Option(name: "Alzate laterali con manubri", pattern: "raise_l", cue: "Fino all'altezza delle spalle."),
            Option(name: "Alzate laterali al cavo", pattern: "raise_l", cue: "Cavo dietro al corpo, sali lento."),
            Option(name: "Alzate laterali alla macchina", pattern: "raise_l", cue: "Gomiti guidano il movimento."),
        ],
    ]

    static func alternatives(for exercise: Exercise) -> [Option] {
        let fromPlan = exercise.busy.map { Option(name: $0, pattern: PlanParser.pattern(for: $0), cue: "Alternativa indicata nella tua scheda.") }
        let generic = (options[exercise.pattern] ?? []).filter { o in o.name != exercise.name && !fromPlan.contains { $0.name.lowercased() == o.name.lowercased() } }
        return fromPlan + generic
    }

    private static func key(_ original: String, day: String) -> String { "swap.\(day).\(original)" }

    /// The exercise done instead of `original` on `day`, if any.
    static func swap(for original: String, day: String = DayId.today) -> Option? {
        guard let name = UserDefaults.standard.string(forKey: key(original, day: day)) else { return nil }
        return options.values.joined().first { $0.name == name }
            ?? Option(name: name, pattern: PlanParser.pattern(for: name), cue: "Alternativa indicata nella tua scheda.")
    }

    static func set(_ option: Option?, for original: String, day: String = DayId.today) {
        if let option { UserDefaults.standard.set(option.name, forKey: key(original, day: day)) }
        else { UserDefaults.standard.removeObject(forKey: key(original, day: day)) }
    }

    /// The exercise to show today: the original, or its replacement with the same sets and reps.
    static func resolved(_ exercise: Exercise, day: String = DayId.today) -> Exercise {
        guard let option = swap(for: exercise.name, day: day) else { return exercise }
        var e = exercise
        e.name = option.name
        e.pattern = option.pattern
        e.cue = option.cue
        return e
    }

    /// Plan exercise or known alternative whose name best matches free text ("panca", "lat"): used by the coach chat.
    static func match(_ text: String) -> String? {
        let all = WorkoutPlan.days.flatMap { $0.blocks.flatMap { $0.exercises.flatMap { [$0.name] + $0.busy } } } + options.values.joined().map(\.name)
        let words = FoodDatabase.normalize(text).split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count > 2 }
        guard !words.isEmpty else { return nil }
        var best: (String, Int)?
        for name in Set(all) {
            let n = FoodDatabase.normalize(name)
            let hits = words.filter { n.contains($0) }.count
            if hits > 0, hits > (best?.1 ?? 0) || hits == best?.1 && name.count < (best?.0.count ?? .max) { best = (name, hits) }
        }
        return best?.0
    }
}

/// Weekly set wave: week 1 → 3 sets per exercise, week 2 → 4, week 3 → 5; then more weight and back to 3.
/// Deload weeks keep their own sets.
enum SetWave {
    private static let key = "wave.start"

    /// Monday of the week the current wave started (set the first time it is needed: that week has 3 sets).
    static var start: Date {
        get {
            if let saved = UserDefaults.standard.object(forKey: key) as? Date { return saved }
            let monday = mondayOf(.now)
            UserDefaults.standard.set(monday, forKey: key)
            return monday
        }
        set { UserDefaults.standard.set(mondayOf(newValue), forKey: key) }
    }

    static func mondayOf(_ date: Date) -> Date {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        return cal.dateInterval(of: .weekOfYear, for: date)?.start ?? Calendar.current.startOfDay(for: date)
    }

    /// 0, 1 or 2: the week of the wave `date` falls in.
    static func week(on date: Date = .now, start: Date = start) -> Int {
        let weeks = Calendar.current.dateComponents([.day], from: mondayOf(start), to: mondayOf(date)).day.map { $0 / 7 } ?? 0
        return ((weeks % 3) + 3) % 3
    }

    static func sets(on date: Date = .now, start: Date = start) -> Int { 3 + week(on: date, start: start) }

    /// Picks the week of the wave for this week (3, 4 or 5 sets), moving the start back accordingly.
    static func setThisWeek(sets: Int, today: Date = .now) {
        let back = max(0, min(2, sets - 3))
        start = Calendar.current.date(byAdding: .day, value: -7 * back, to: mondayOf(today)) ?? today
    }

    static func apply(_ exercise: Exercise, phase: Progression.Phase, on date: Date = .now) -> Exercise {
        guard phase != .deload else { return exercise }
        var e = exercise
        e.sets = sets(on: date)
        return e
    }

    static var title: String {
        switch week() {
        case 0: "Settimana da 3 serie · carico nuovo"
        case 1: "Settimana da 4 serie · stesso carico"
        default: "Settimana da 5 serie · la prossima aumenti i kg"
        }
    }

    /// The load to use, from the best weight of the last session and whether a new wave has started since.
    static func advice(lastBest: Double, lastDay: String, today: Date = .now) -> String {
        let step = lastBest < 20 ? 1.0 : 2.5
        let lastDate = DayId.date(lastDay)
        let newWave = week(on: today) == 0 && week(on: lastDate) != 0
        if newWave && lastBest > 0 {
            return "Nuova settimana da 3 serie: aumenta il carico, prova \((lastBest + step).it(1)) kg (l'ultima volta \(lastBest.it(1)) kg)."
        }
        return "\(sets(on: today)) serie con \(lastBest.it(1)) kg, come l'ultima volta."
    }
}
