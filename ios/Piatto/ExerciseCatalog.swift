import SwiftUI

/// 870+ exercises from Free Exercise DB (public domain, github.com/yuhonas/free-exercise-db), with the
/// illustrated 4-frame animations drawn for Fud AI (MIT, github.com/apoorvdarshan/fud-ai). Neither is bundled:
/// the list is downloaded once and kept on the iPhone, frames are loaded when shown (and cached by URLCache).
final class ExerciseCatalog: ObservableObject {
    static let shared = ExerciseCatalog()

    struct Item: Codable, Identifiable, Hashable {
        var id: String
        var name: String
        var primaryMuscles: [String]
        var secondaryMuscles: [String]?
        var equipment: String?
        var level: String?
        var category: String?
        var instructions: [String]
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var loading = false
    @Published private(set) var failed = false

    private static let source = URL(string: "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/dist/exercises.json")!
    private static let frameBase = "https://raw.githubusercontent.com/apoorvdarshan/fud-ai/main/shared/workout-vectors/"
    private static var cache: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("free-exercise-db.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.cache), let list = try? JSONDecoder().decode([Item].self, from: data) { items = list }
    }

    /// Downloads the list the first time (about 1 MB); afterwards it works offline.
    @MainActor func loadIfNeeded() async {
        guard items.isEmpty, !loading else { return }
        loading = true
        failed = false
        defer { loading = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.source)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let list = try JSONDecoder().decode([Item].self, from: data).filter { $0.category != "stretching" }
            items = list.sorted { $0.name < $1.name }
            try? JSONEncoder().encode(items).write(to: Self.cache)
            DebugLog.shared.add("info", "workout", "Catalogo esercizi scaricato: \(items.count)")
        } catch {
            failed = true
            DebugLog.shared.add("error", "workout", "Catalogo esercizi non scaricato: \(error.localizedDescription)")
        }
    }

    /// The illustrated frames of an exercise (4, setup → action → return).
    static func frames(_ id: String, female: Bool) -> [URL] {
        let gender = female ? "female" : "male"
        return (0..<4).compactMap { i in
            let name = "\(id)_\(gender)_v2_\(i).png".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            return URL(string: frameBase + name)
        }
    }

    func item(named name: String) -> Item? {
        if let exact = items.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return exact }
        let n = name.lowercased()
        guard let id = Self.italian.first(where: { key, _ in n.contains(key) })?.value else { return nil }
        return items.first { $0.id == id }
    }

    /// Exercises that train the same muscles as a movement pattern.
    func alternatives(pattern: String, query: String) -> [Item] {
        let muscles = Self.muscles(for: pattern)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { item in
            if !q.isEmpty {
                return item.name.lowercased().contains(q) || item.primaryMuscles.contains { Self.muscleName($0).lowercased().contains(q) }
            }
            return item.primaryMuscles.contains(where: muscles.contains)
        }
    }

    static func muscles(for pattern: String) -> Set<String> {
        switch pattern {
        case "push_h", "fly": ["chest"]
        case "pull_v", "pullover": ["lats"]
        case "pull_h": ["middle back", "lats"]
        case "push_v", "raise_l", "rear_fly", "face_pull": ["shoulders"]
        case "squat", "leg_ext": ["quadriceps"]
        case "lunge": ["quadriceps", "glutes"]
        case "hinge": ["hamstrings", "lower back", "glutes"]
        case "leg_curl": ["hamstrings"]
        case "hip_thrust": ["glutes"]
        case "calf": ["calves"]
        case "curl": ["biceps"]
        case "tri_oh", "tri_push": ["triceps"]
        case "core": ["abdominals"]
        case "adductor": ["adductors"]
        case "abductor": ["abductors"]
        default: []
        }
    }

    /// The Nomorediet pattern of a catalog exercise (for the stick-figure fallback and the swap list).
    static func pattern(for item: Item) -> String {
        let n = item.name.lowercased()
        switch item.primaryMuscles.first ?? "" {
        case "chest": return n.contains("fly") || n.contains("flye") ? "fly" : "push_h"
        case "lats": return n.contains("pullover") ? "pullover" : n.contains("row") ? "pull_h" : "pull_v"
        case "middle back": return "pull_h"
        case "shoulders": return n.contains("raise") ? (n.contains("rear") ? "rear_fly" : "raise_l") : n.contains("face pull") ? "face_pull" : "push_v"
        case "quadriceps": return n.contains("lunge") || n.contains("split") || n.contains("step") ? "lunge" : n.contains("extension") ? "leg_ext" : "squat"
        case "hamstrings": return n.contains("curl") ? "leg_curl" : "hinge"
        case "lower back": return "hinge"
        case "glutes": return "hip_thrust"
        case "calves": return "calf"
        case "biceps", "forearms": return "curl"
        case "triceps": return n.contains("overhead") || n.contains("french") || n.contains("skull") ? "tri_oh" : "tri_push"
        case "abdominals": return "core"
        case "adductors": return "adductor"
        case "abductors": return "abductor"
        default: return "core"
        }
    }

    static func muscleName(_ m: String) -> String {
        [
            "chest": "petto", "lats": "dorsali", "middle back": "dorso", "lower back": "lombari", "shoulders": "spalle",
            "traps": "trapezi", "neck": "collo", "biceps": "bicipiti", "triceps": "tricipiti", "forearms": "avambracci",
            "abdominals": "addominali", "quadriceps": "quadricipiti", "hamstrings": "femorali", "glutes": "glutei",
            "calves": "polpacci", "adductors": "adduttori", "abductors": "abduttori",
        ][m] ?? m
    }

    static func equipmentName(_ e: String?) -> String {
        guard let e, !e.isEmpty else { return "" }
        return [
            "barbell": "bilanciere", "dumbbell": "manubri", "cable": "cavi", "machine": "macchina", "body only": "corpo libero",
            "kettlebells": "kettlebell", "bands": "elastici", "medicine ball": "palla medica", "exercise ball": "fitball",
            "e-z curl bar": "bilanciere EZ", "foam roll": "rullo", "other": "altro",
        ][e] ?? e
    }

    /// Italian names in Nomorediet's plans → the catalog exercise with the same movement, for the illustrations.
    private static let italian: [(String, String)] = [
        ("panca piana con manubri", "Dumbbell_Bench_Press"), ("panca piana manubri", "Dumbbell_Bench_Press"),
        ("panca piana", "Barbell_Bench_Press_-_Medium_Grip"), ("panca inclinata", "Incline_Dumbbell_Press"),
        ("chest press", "Leverage_Chest_Press"), ("croci ai cavi", "Flat_Bench_Cable_Flyes"), ("croci", "Dumbbell_Flyes"),
        ("pec deck", "Butterfly"), ("piegamenti", "Pushups"),
        ("lat machine", "Wide-Grip_Lat_Pulldown"), ("lat pulldown", "Wide-Grip_Lat_Pulldown"), ("trazioni", "Pullups"),
        ("pullover", "Straight-Arm_Dumbbell_Pullover"), ("pulley", "Seated_Cable_Rows"),
        ("rematore manubrio", "One-Arm_Dumbbell_Row"), ("rematore con manubrio", "One-Arm_Dumbbell_Row"),
        ("rematore con bilanciere", "Bent_Over_Barbell_Row"), ("rematore", "Seated_Cable_Rows"),
        ("face pull", "Face_Pull"), ("military press", "Dumbbell_Shoulder_Press"), ("lento avanti", "Dumbbell_Shoulder_Press"),
        ("shoulder press", "Leverage_Shoulder_Press"), ("arnold", "Arnold_Dumbbell_Press"),
        ("alzate laterali al cavo", "Cable_Seated_Lateral_Raise"), ("alzate laterali", "Side_Lateral_Raise"),
        ("alzate posteriori", "Seated_Bent-Over_Rear_Delt_Raise"), ("rear delt", "Cable_Rear_Delt_Fly"),
        ("reverse pec deck", "Reverse_Machine_Flyes"),
        ("curl martello", "Hammer_Curls"), ("curl a martello", "Hammer_Curls"), ("curl su panca inclinata", "Incline_Dumbbell_Curl"),
        ("curl al cavo", "Standing_Biceps_Cable_Curl"), ("curl", "Dumbbell_Bicep_Curl"),
        ("tricipiti cavo", "Triceps_Pushdown_-_Rope_Attachment"), ("push-down", "Triceps_Pushdown"),
        ("estensioni tricipiti", "Cable_Rope_Overhead_Triceps_Extension"), ("french press", "EZ-Bar_Skullcrusher"),
        ("leg press", "Leg_Press"), ("hack squat", "Barbell_Hack_Squat"), ("goblet squat", "Goblet_Squat"), ("squat", "Barbell_Full_Squat"),
        ("leg curl sdraiato", "Lying_Leg_Curls"), ("leg curl", "Seated_Leg_Curl"), ("seated leg curl", "Seated_Leg_Curl"),
        ("leg extension", "Leg_Extensions"), ("adductor", "Thigh_Adductor"), ("abductor", "Thigh_Abductor"),
        ("stacco rumeno", "Romanian_Deadlift"), ("stacco", "Romanian_Deadlift"), ("hyperextension", "Hyperextensions_Back_Extensions"),
        ("affondi", "Dumbbell_Lunges"), ("split squat", "Split_Squat_with_Dumbbells"), ("step-up", "Dumbbell_Step_Ups"),
        ("hip thrust", "Barbell_Hip_Thrust"), ("glute bridge", "Barbell_Glute_Bridge"),
        ("calf", "Standing_Calf_Raises"), ("crunch al cavo", "Cable_Crunch"), ("crunch", "Crunches"), ("plank", "Plank"),
    ]
}

/// The catalog animation: the 4 illustrated frames in a loop, or Nomorediet's stick figure while they load.
struct CatalogFigure: View {
    var id: String
    var pattern: String
    var size: CGFloat
    @ObservedObject private var profile = ProfileStore.shared
    @State private var frame = 0
    private let tick = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    var body: some View {
        let urls = ExerciseCatalog.frames(id, female: profile.profile.sex == .donna)
        AsyncImage(url: urls[frame % urls.count], transaction: Transaction(animation: nil)) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else {
                MovementFigure(pattern: pattern, size: size)
            }
        }
        .frame(width: size, height: size)
        .background(Color.white.opacity(0.9))
        .onReceive(tick) { _ in frame += 1 }
    }
}

/// Full catalog search inside "Cambia esercizio".
struct CatalogSwapSection: View {
    var pattern: String
    var pick: (ExerciseSwaps.Option) -> Void
    @ObservedObject private var catalog = ExerciseCatalog.shared
    @State private var query = ""
    @State private var detail: ExerciseCatalog.Item?

    var body: some View {
        Section {
            if catalog.items.isEmpty {
                if catalog.loading { HStack { ProgressView(); Text("Scarico il catalogo…").foregroundStyle(.secondary) } }
                else {
                    Button("Scarica il catalogo di 870 esercizi") { Task { await catalog.loadIfNeeded() } }
                    if catalog.failed { Text("Serve la connessione la prima volta.").font(.caption).foregroundStyle(.secondary) }
                }
            } else {
                TextField("Cerca (es. row, curl, glutei)", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                let list = catalog.alternatives(pattern: pattern, query: query)
                ForEach(list.prefix(60)) { item in
                    Button { detail = item } label: {
                        HStack(spacing: 12) {
                            CatalogFigure(id: item.id, pattern: ExerciseCatalog.pattern(for: item), size: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).font(.subheadline.weight(.semibold))
                                Text(([ExerciseCatalog.equipmentName(item.equipment)] + item.primaryMuscles.map(ExerciseCatalog.muscleName))
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                if list.count > 60 { Text("\(list.count - 60) altri: affina la ricerca.").font(.caption).foregroundStyle(.secondary) }
            }
        } header: {
            Text("Catalogo completo")
        } footer: {
            Text("Esercizi da Free Exercise DB (pubblico dominio), illustrazioni di Fud AI (licenza MIT).")
        }
        .task { await catalog.loadIfNeeded() }
        .sheet(item: $detail) { item in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        CatalogFigure(id: item.id, pattern: ExerciseCatalog.pattern(for: item), size: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 18)).frame(maxWidth: .infinity)
                        Text(item.primaryMuscles.map(ExerciseCatalog.muscleName).joined(separator: ", ").capitalized)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                        ForEach(Array(item.instructions.enumerated()), id: \.offset) { i, step in
                            Text("\(i + 1). \(step)").font(.subheadline)
                        }
                        Button {
                            pick(ExerciseSwaps.Option(name: item.name, pattern: ExerciseCatalog.pattern(for: item),
                                                      cue: item.instructions.first ?? ""))
                            detail = nil
                        } label: { Label("Usa questo esercizio oggi", systemImage: "checkmark").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                }
                .navigationTitle(item.name)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}
