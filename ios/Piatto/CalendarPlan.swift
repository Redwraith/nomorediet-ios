import EventKit
import Foundation

/// The workout plan the user follows from Google Calendar ("💪 A1 — Petto/Schiena (Ciclo 2)" events with
/// "1A) PANCA PIANA MANUBRI — 4×6-10" lines). A copy of Ciclo 2 ships with the app; "Aggiorna dal
/// Calendario" reads the events again from the iPhone's Calendar app (where the Google account is added),
/// so a new cycle written in Google Calendar arrives in the app without an update.
final class PlanStore: ObservableObject {
    static let shared = PlanStore()

    enum Source: String, Codable { case calendar, nomorediet }

    @Published private(set) var calendarDays: [WorkoutDay]
    @Published private(set) var cycle: Cycle
    @Published private(set) var importedAt: Date?
    @Published var source: Source {
        didSet { UserDefaults.standard.set(source.rawValue, forKey: "plan.source") }
    }

    /// The plan for the profile's sex: Nomorediet has a men's (shoulders and back) and a women's (glutes and legs) plan.
    var days: [WorkoutDay] {
        if source == .calendar { return WorkoutPlan.withExtras(calendarDays) }
        return Progression.withRoles(ProfileStore.shared.profile.sex == .donna ? WorkoutPlan.womenDays : WorkoutPlan.nomoredietDays)
    }
    var name: String {
        if source == .calendar { return "Scheda del Calendario · \(cycle.name)" }
        return ProfileStore.shared.profile.sex == .donna ? "Nomorediet · glutei e tonificazione" : "Nomorediet · spalle e dorso"
    }

    private static let key = "plan.calendar.v1"

    private struct Saved: Codable {
        var days: [WorkoutDay]
        var cycle: Cycle
        var importedAt: Date
    }

    private init() {
        source = Source(rawValue: UserDefaults.standard.string(forKey: "plan.source") ?? "") ?? .calendar
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode(Saved.self, from: data), !saved.days.isEmpty {
            calendarDays = saved.days
            cycle = saved.cycle
            importedAt = saved.importedAt
        } else {
            calendarDays = CalendarProgram.ciclo2.compactMap { PlanParser.day(title: $0.title, description: $0.text) }
            cycle = PlanParser.cycle(from: CalendarProgram.ciclo2.first?.text ?? "", year: 2026, name: "Ciclo 2") ?? .ciclo2
        }
    }

    /// Reads the plan from the Calendar app: events of the last 3 weeks and next 3 weeks with "1A)" lines.
    /// Returns a message for the user.
    @MainActor func syncFromCalendar() async -> String {
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        guard granted else { return "Consenti l'accesso al Calendario in Impostazioni → Nomorediet → Calendari." }
        let start = Calendar.current.date(byAdding: .day, value: -21, to: .now)!
        let end = Calendar.current.date(byAdding: .day, value: 21, to: .now)!
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { ($0.notes ?? "").contains("1A)") }
            .sorted { abs($0.startDate.timeIntervalSinceNow) < abs($1.startDate.timeIntervalSinceNow) }
        guard !events.isEmpty else {
            return "Nessuna scheda trovata nel Calendario dell'iPhone. Aggiungi il tuo account Google in Impostazioni → App → Calendario → Account, poi riprova."
        }
        // one day per code (A1, A2, B1, B2…), the event nearest to today; ordered by weekday
        var byCode: [String: (WorkoutDay, Int)] = [:]
        for event in events {
            guard let day = PlanParser.day(title: event.title ?? "", description: event.notes ?? ""), byCode[day.name] == nil else { continue }
            let weekday = (Calendar.current.component(.weekday, from: event.startDate) + 5) % 7 // Monday = 0
            byCode[day.name] = (day, weekday)
        }
        let days = byCode.values.sorted { $0.1 < $1.1 }.map(\.0)
        let year = Calendar.current.component(.year, from: .now)
        let cycleName = PlanParser.cycleName(events.first?.title ?? "") ?? cycle.name
        let newCycle = PlanParser.cycle(from: events.first?.notes ?? "", year: year, name: cycleName) ?? cycle
        let weekdays = Set(byCode.values.map { ($0.1 + 1) % 7 + 1 }) // back to Calendar weekdays
        calendarDays = days
        cycle = newCycle
        importedAt = Date()
        source = .calendar
        if weekdays.count == days.count { ProfileStore.shared.profile.trainingWeekdaySet = weekdays }
        if let data = try? JSONEncoder().encode(Saved(days: days, cycle: newCycle, importedAt: Date())) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        return "Scheda aggiornata dal Calendario: \(days.map(\.name).joined(separator: ", ")) · \(newCycle.name)."
    }
}

/// Months, deloads and end of the cycle, from the "📅 MESE" and "🟡 SCARICO" lines.
struct Cycle: Codable, Equatable {
    var name: String
    var month1End: Date
    var month2: ClosedRange<Date>
    var month3: ClosedRange<Date>
    var deloads: [ClosedRange<Date>]

    static let ciclo2: Cycle = {
        func d(_ day: Int, _ month: Int) -> Date { Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day))! }
        return Cycle(name: "Ciclo 2", month1End: d(20, 9), month2: d(21, 9)...d(18, 10), month3: d(19, 10)...d(15, 11),
                     deloads: [d(14, 9)...d(20, 9), d(12, 10)...d(18, 10), d(9, 11)...d(15, 11)])
    }()
}

enum PlanParser {
    /// "💪 A1 — Petto/Schiena (Ciclo 2)" + description → a workout day.
    static func day(title: String, description: String) -> WorkoutDay? {
        let titleText = title.unicodeScalars.filter { $0.properties.isEmojiPresentation == false || $0.isASCII }.map(String.init).joined()
        let parts = titleText.components(separatedBy: "—").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return nil }
        let code = parts[0].components(separatedBy: .whitespaces).last { !$0.isEmpty } ?? parts[0]
        let focus = parts[1].replacingOccurrences(of: "\\s*\\(.*\\)\\s*$", with: "", options: .regularExpression)

        var blocks: [ExerciseBlock] = []
        let line = try! NSRegularExpression(pattern: #"^(\d+)([A-Z])\)\s*(.+?)\s+[—–-]\s+(\d+)\s*[×x]\s*([\d]+(?:\s*[-–]\s*\d+)?)(.*)$"#)
        let rest = try! NSRegularExpression(pattern: #"(\d+)\s*["”″]\s*recupero"#)
        for raw in description.components(separatedBy: .newlines) {
            let text = raw.trimmingCharacters(in: .whitespaces)
            let ns = text as NSString
            if let m = line.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                let number = ns.substring(with: m.range(at: 1))
                let rawName = ns.substring(with: m.range(at: 3))
                let sets = Int(ns.substring(with: m.range(at: 4))) ?? 3
                let reps = ns.substring(with: m.range(at: 5)).replacingOccurrences(of: "-", with: "–").replacingOccurrences(of: " ", with: "")
                let tail = ns.substring(with: m.range(at: 6))
                if blocks.last?.label != number { blocks.append(ExerciseBlock(label: number, restSeconds: 75, exercises: [])) }
                let (name, extra) = Self.name(rawName)
                let pattern = Self.pattern(for: name)
                let dropset = tail.range(of: #"DROPSET\s*-?\d+%"#, options: .regularExpression).map { String(tail[$0]).replacingOccurrences(of: "DROPSET", with: "Dropset") }
                let role: Exercise.Role = number == "1" ? .fondamentale : Self.isCompound(name) ? .complementare : .isolamento
                let tips = Self.tips[pattern] ?? ("Movimento controllato, senza slancio.", "Arriva in fondo al movimento a ogni ripetizione.")
                blocks[blocks.count - 1].exercises.append(Exercise(
                    name: name, pattern: pattern, sets: sets, reps: reps, rir: number == "1" ? "1–2" : "1",
                    cue: extra.isEmpty ? tips.0 : extra.prefix(1).uppercased() + extra.dropFirst() + ". " + tips.0,
                    stretch: tips.1, role: role, dropset: dropset))
            } else if text.hasPrefix("↳"), !blocks.isEmpty {
                if let m = rest.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                    blocks[blocks.count - 1].restSeconds = Int(ns.substring(with: m.range(at: 1))) ?? 75
                }
                if let colon = text.range(of: "Se occupato:") {
                    let options = text[colon.upperBound...].components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    for (i, option) in options.enumerated() where i < blocks[blocks.count - 1].exercises.count {
                        blocks[blocks.count - 1].exercises[i].busy = [option.prefix(1).uppercased() + option.dropFirst()]
                    }
                }
            }
        }
        guard !blocks.isEmpty else { return nil }
        // jump-set letters: 1, 2, 3 → A, B, C as shown in the app
        let letters = ["A", "B", "C", "D", "E"]
        for i in blocks.indices where i < letters.count { blocks[i].label = letters[i] }
        return WorkoutDay(name: code, focus: focus, blocks: blocks)
    }

    /// "(Ciclo 2)" from the title.
    static func cycleName(_ title: String) -> String? {
        guard let range = title.range(of: #"\(([^)]+)\)"#, options: .regularExpression) else { return nil }
        return String(title[range].dropFirst().dropLast())
    }

    /// Month and deload dates from lines like "📅 MESE 2 (21/09→18/10)" and "🟡 SCARICO 14-20/09 · 12-18/10 · 09-15/11".
    static func cycle(from description: String, year: Int, name: String) -> Cycle? {
        func date(_ day: String, _ month: String) -> Date? {
            guard let d = Int(day), let m = Int(month) else { return nil }
            return Calendar.current.date(from: DateComponents(year: year, month: m, day: d))
        }
        func matches(_ pattern: String) -> [[String]] {
            let re = try! NSRegularExpression(pattern: pattern)
            let ns = description as NSString
            return re.matches(in: description, range: NSRange(location: 0, length: ns.length)).map { m in
                (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
            }
        }
        let month1 = matches(#"MESE 1 \(fino al (\d{1,2})/(\d{1,2})\)"#).first.flatMap { date($0[0], $0[1]) }
        let ranges = matches(#"MESE (\d) \((\d{1,2})/(\d{1,2})\s*→\s*(\d{1,2})/(\d{1,2})\)"#)
        func range(_ n: String) -> ClosedRange<Date>? {
            guard let r = ranges.first(where: { $0[0] == n }), let a = date(r[1], r[2]), let b = date(r[3], r[4]), a <= b else { return nil }
            return a...b
        }
        let deloads = matches(#"(\d{1,2})-(\d{1,2})/(\d{1,2})"#).compactMap { r -> ClosedRange<Date>? in
            guard let a = date(r[0], r[2]), let b = date(r[1], r[2]), a <= b else { return nil }
            return a...b
        }
        guard let m2 = range("2"), let m3 = range("3") else { return nil }
        return Cycle(name: name, month1End: month1 ?? m2.lowerBound.addingTimeInterval(-86400), month2: m2, month3: m3, deloads: deloads)
    }

    /// "PANCA PIANA MANUBRI (neutra)" → ("Panca piana manubri (neutra)", ""), "LEG CURL SDRAIATO (ecc. 3\")" → name + technique.
    static func name(_ raw: String) -> (String, String) {
        var name = raw
        var extra = ""
        // technique notes in brackets ("ecc. 3\"", "pausa 1-2\" picco") or after a dash become the cue
        if let range = name.range(of: #"\((ecc|pausa)[^)]*\)"#, options: .regularExpression) {
            extra = String(name[range].dropFirst().dropLast())
            name.removeSubrange(range)
        }
        if let dash = name.range(of: " — ") {
            extra = String(name[dash.upperBound...])
            name = String(name[..<dash.lowerBound])
        }
        let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
        return (lower.prefix(1).uppercased() + lower.dropFirst(), extra.trimmingCharacters(in: .whitespaces))
    }

    static func isCompound(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["panca", "lat ", "lat machine", "rematore", "pulley", "press", "stacco", "squat", "affondi", "trazioni", "pulldown", "dip"].contains { n.contains($0) }
    }

    /// Animation and rep-counting pattern from the exercise name.
    static func pattern(for name: String) -> String {
        let n = name.lowercased()
        let rules: [(String, [String])] = [
            ("pullover", ["pullover"]),
            ("adductor", ["adductor", "adduzion", "adduttor"]),
            ("abductor", ["abductor", "abduzion", "abduttor"]),
            ("rear_fly", ["rear delt", "posterior", "reverse"]),
            ("face_pull", ["face pull"]),
            ("raise_l", ["alzate laterali", "laterali"]),
            ("fly", ["croci", "pec deck", "chest fly"]),
            ("leg_curl", ["leg curl", "curl sdraiato", "nordic"]),
            ("leg_ext", ["leg extension"]),
            ("calf", ["calf", "polpacci"]),
            ("hip_thrust", ["hip thrust", "glute bridge", "ponte"]),
            ("hinge", ["stacco", "good morning", "hyperextension"]),
            ("lunge", ["affondi", "split squat", "step-up", "bulgaro"]),
            ("squat", ["squat", "leg press", "hack"]),
            ("push_v", ["military", "lento", "shoulder press", "arnold"]),
            ("pull_v", ["lat machine", "lat pulldown", "pulldown", "trazioni"]),
            ("pull_h", ["rematore", "pulley", "row", "t-bar"]),
            ("tri_push", ["push-down", "pushdown", "dip"]),
            ("tri_oh", ["tricipiti", "french", "estension"]),
            ("curl", ["curl"]),
            ("push_h", ["panca", "chest press", "piegamenti"]),
            ("core", ["crunch", "plank", "addom"]),
        ]
        return rules.first { $0.1.contains(where: n.contains) }?.0 ?? "push_h"
    }

    static let tips: [String: (String, String)] = [
        "push_h": ("Scapole strette, scendi controllato fino al petto.", "La discesa profonda allunga il pettorale."),
        "pull_v": ("Tira i gomiti verso i fianchi, petto alto.", "In alto lascia salire le scapole e senti il dorsale tirare."),
        "pull_h": ("Tira il gomito verso l'anca, busto fermo.", "In avanti lascia allungare il dorsale prima di ogni ripetizione."),
        "fly": ("Gomiti morbidi e fissi, apri ad arco.", "Apri finché senti il petto allungarsi."),
        "pullover": ("Braccia quasi tese, porta la barra dalle spalle alle cosce.", "In alto lascia salire le braccia: il dorsale si allunga."),
        "push_v": ("Glutei contratti, spingi dritto sopra la testa.", "Scendi fino a sotto il mento."),
        "raise_l": ("Sali fino all'altezza delle spalle, lento.", "Parti con il braccio davanti al bacino."),
        "rear_fly": ("Apri le braccia indietro con i gomiti morbidi.", "Lascia incrociare le braccia davanti."),
        "face_pull": ("Corda verso la fronte, gomiti alti.", "Lascia distendere le braccia in avanti."),
        "curl": ("Gomiti fermi ai fianchi.", "Scendi fino a braccio completamente disteso."),
        "tri_oh": ("Gomiti vicini alla testa, braccio fermo.", "Braccio sopra la testa: capo lungo del tricipite in allungamento."),
        "tri_push": ("Gomiti fermi ai fianchi.", "Risali fino a superare i 90° al gomito."),
        "squat": ("Spingi con tutto il piede, ginocchia in linea con le punte.", "Scendi profondo controllando la discesa."),
        "hinge": ("Anche indietro, schiena neutra, peso vicino alle gambe.", "Scendi finché senti tirare i femorali."),
        "lunge": ("Passo lungo, busto stabile.", "Scendi finché il ginocchio dietro sfiora terra."),
        "leg_curl": ("Bacino fermo, controlla la risalita.", "Lascia distendere completamente il ginocchio."),
        "leg_ext": ("Sali fino quasi a distendere.", "Scendi fino a ginocchio ben piegato."),
        "adductor": ("Chiudi le gambe controllando, senza slancio.", "Apri il più possibile senza fastidio all'inguine."),
        "abductor": ("Apri le gambe e tieni 1 s in fuori.", "Torna dentro lentamente."),
        "calf": ("Sali sulle punte, ritmo lento.", "Pausa con il tallone in basso."),
        "hip_thrust": ("Mento in basso, spingi con i talloni.", "Scendi con il bacino fino quasi a terra."),
        "core": ("Arrotola la colonna, niente slancio.", "Torna ben disteso prima di ogni ripetizione."),
    ]
}

/// Ciclo 2 as written in Google Calendar (October 2026): the copy used until the first sync.
enum CalendarProgram {
    struct Event { let title: String; let text: String }

    static let months = """
    📅 MESE 1 (fino al 20/09): serie/rep come sopra, +1 rep o +2,5 kg a settimana
    📅 MESE 2 (21/09→18/10): tempo 3-1-1-0, carichi -10%
    📅 MESE 3 (19/10→15/11): 4×6-8 + rest-pause, dropset diventano DOPPI
    🟡 SCARICO 14-20/09 · 12-18/10 · 09-15/11: carico 60%, no dropset, mai a cedimento
    """

    static let ciclo2: [Event] = [
        Event(title: "💪 A1 — Petto/Schiena (Ciclo 2)", text: """
        1A) PANCA PIANA MANUBRI (neutra) — 4×6-10
        1B) REMATORE MANUBRIO un braccio — 4×6-10
        ↳ JUMPSET: 1A → subito 1B → 90" recupero → ripeti
        ↳ Se occupato: chest press macchina / rematore chest-supported
        2A) PANCA INCLINATA MANUBRI 30° — 3×10-15
        2B) LAT MACHINE (neutra) — 3×10-15 🔻 DROPSET -20% ultima serie
        ↳ JUMPSET: 2A → subito 2B → 75" recupero
        ↳ Se occupato: chest press inclinata / pulldown un braccio
        3A) CROCI AI CAVI — 3×12-15
        3B) PULLOVER AL CAVO — 3×12-15 🔻 DROPSET -25% ultima serie
        ↳ JUMPSET: 3A → subito 3B → 60" recupero
        ↳ Se occupato: croci manubri / pullover manubrio
        """ + "\n" + months),
        Event(title: "🦵 A2 — Quadricipiti/Adduttori (Ciclo 2)", text: """
        1A) LEG PRESS piedi medi — 4×6-10
        1B) LEG CURL SDRAIATO (ecc. 3") — 4×6-10
        ↳ JUMPSET antagonisti: 1A → subito 1B → 120" recupero → ripeti
        ↳ Se occupato: goblet squat / leg curl seduto
        2A) LEG EXTENSION (pausa 1-2" picco) — 3×12-15 🔻 DROPSET -25% ultima serie
        2B) ADDUCTOR MACHINE (ecc. lenta) — 3×12-15
        ↳ JUMPSET: 2A → subito 2B → 75" recupero
        ↳ Se occupato: split squat bulgaro / adduzioni al cavo
        """ + "\n" + months),
        Event(title: "💪 B1 — Spalle/Braccia (Ciclo 2)", text: """
        1A) MILITARY PRESS MANUBRI seduto (neutra) — 4×6-10
        1B) PULLEY BASSO (neutra) — 4×6-10
        ↳ JUMPSET: 1A → subito 1B → 90" recupero → ripeti
        ↳ Se occupato: shoulder press macchina / rematore un braccio al cavo
        2A) ALZATE LATERALI AL CAVO — 3×12-15
        2B) REAR DELT MACHINE — 3×12-15 🔻 DROPSET -25% ultima serie
        ↳ JUMPSET: 2A → subito 2B → 60" recupero
        ↳ Se occupato: alzate manubri / alzate posteriori busto flesso
        3A) CURL MARTELLO — 3×12-15
        3B) TRICIPITI CAVO BASSO (corda) — 3×12-15 🔻 DROPSET -25% ultima serie
        ↳ JUMPSET: 3A → subito 3B → 60" recupero
        ↳ Se occupato: curl corda al cavo / estensioni monomanubrio dietro testa
        """ + "\n" + months),
        Event(title: "🦵 B2 — Femorali/Glutei (Ciclo 2)", text: """
        1A) STACCO RUMENO MANUBRI (stretch femorali) — 4×6-10
        1B) AFFONDI CON MANUBRI — 4×6-10
        ↳ JUMPSET antagonisti: 1A → subito 1B → 120" recupero → ripeti
        ↳ Se occupato: hyperextension 45° / step-up su panca
        2A) SEATED LEG CURL — pausa in stretch — 3×12-15 🔻 DROPSET -25% ultima serie
        2B) ABDUCTOR MACHINE — 3×12-15
        ↳ JUMPSET: 2A → subito 2B → 75" recupero
        ↳ Se occupato: leg curl sdraiato / abduzioni al cavo
        """ + "\n" + months),
    ]
}
