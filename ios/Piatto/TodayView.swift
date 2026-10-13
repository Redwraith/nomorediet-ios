import SwiftData
import SwiftUI

/// Shared navigation state: selected tab, open sheets and the day shown.
final class AppState: ObservableObject {
    enum Tab: Hashable { case oggi, progressi, allenamento, coach, profilo }
    enum Sheet: Identifiable {
        case addFood(MealSlot, AddFoodView.Mode)
        case weight(WeightSheet.Mode)
        case debug
        var id: String {
            switch self {
            case .addFood(let slot, let mode): "food-\(slot.rawValue)-\(mode)"
            case .weight(let mode): "weight-\(mode)"
            case .debug: "debug"
            }
        }
    }
    @Published var tab = Tab.oggi
    @Published var sheet: Sheet?
    @Published var day = DayId.today
    /// Open today's workout session (arriving at the gym, Siri).
    @Published var openWorkout = false
}

struct TodayView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: ProfileStore
    @Environment(\.modelContext) private var context
    @Query private var entries: [FoodEntry]
    @Query private var dayInfos: [DayInfo]
    @Query(sort: \SavedMeal.uses, order: .reverse) private var saved: [SavedMeal]
    @Query(sort: \WeightEntry.createdAt, order: .reverse) private var weights: [WeightEntry]

    private var dayEntries: [FoodEntry] { entries.filter { $0.day == app.day }.sorted { $0.createdAt < $1.createdAt } }
    private var kind: DayKind { DayKind.of(app.day, saved: dayInfos.first { $0.day == app.day }?.kind, profile: store.profile) }
    private var goals: Goals { Nutrition.goals(store.profile, kind: kind) }
    private var totals: Nutrients { dayEntries.reduce(.zero) { $0 + $1.nutrients } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    daySwitcher
                    RingsCard(totals: totals, goals: goals, big: store.profile.simpleMode)
                    dayKindPicker
                    if app.day == DayId.today { SupplementsCard() }
                    if store.profile.simpleMode { simpleButtons }
                    if !saved.isEmpty { repeatRow }
                    ForEach(MealSlot.allCases) { slot in mealSection(slot) }
                    if !store.profile.simpleMode { MicronutrientsCard(totals: totals, goals: goals, vegetarian: store.profile.vegetarian) }
                    weightRow
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(DayId.label(app.day))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(MealSlot.allCases) { slot in
                            Button { app.sheet = .addFood(slot, .search) } label: { Label(slot.title, systemImage: slot.icon) }
                        }
                    } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                    primaryAction: { app.sheet = .addFood(.now, .search) }
                    .accessibilityIdentifier("add-food")
                }
            }
            .onChange(of: dayEntries.count) { _, _ in Sync.afterFoodChange(context: context, day: app.day) }
        }
    }

    private var daySwitcher: some View {
        HStack {
            Button { withAnimation(.snappy) { app.day = DayId.shift(app.day, by: -1) } } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(DayId.date(app.day).formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "it_IT"))))
                .font(.subheadline).foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Spacer()
            Button { withAnimation(.snappy) { app.day = DayId.shift(app.day, by: 1) } } label: { Image(systemName: "chevron.right") }
                .disabled(app.day >= DayId.today)
        }
        .font(.headline)
        .padding(.top, 4)
    }

    private var dayKindPicker: some View {
        Picker("Tipo di giornata", selection: Binding(
            get: { kind },
            set: { new in
                if let info = dayInfos.first(where: { $0.day == app.day }) { info.kind = new }
                else { context.insert(DayInfo(day: app.day, kind: new)) }
                if new == .training && app.day == DayId.today { Supplements.markTrained() }
                Sync.afterFoodChange(context: context, day: app.day)
            })) {
            Label("Allenamento", systemImage: "dumbbell.fill").tag(DayKind.training)
            Label("Riposo", systemImage: "bed.double.fill").tag(DayKind.rest)
        }
        .pickerStyle(.segmented)
    }

    private var simpleButtons: some View {
        HStack(spacing: 12) {
            BigButton(title: "Aggiungi cibo", icon: "plus", tint: Theme.accent) { app.sheet = .addFood(.now, .search) }
            BigButton(title: "Foto", icon: "camera.fill", tint: .orange) { app.sheet = .addFood(.now, .photo) }
            BigButton(title: "Dillo", icon: "mic.fill", tint: .purple) { app.sheet = .addFood(.now, .describe) }
            BigButton(title: "Peso", icon: "scalemass.fill", tint: .blue) { app.sheet = .weight(.type) }
        }
    }

    private var repeatRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ripeti").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(saved.prefix(8)) { meal in
                        Button { Sync.repeatMeal(meal, slot: .now, day: app.day, context: context) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meal.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text("\(meal.kcal.it()) kcal").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Elimina dai preferiti", role: .destructive) { context.delete(meal) }
                        }
                    }
                }
            }
        }
    }

    private func mealSection(_ slot: MealSlot) -> some View {
        let items = dayEntries.filter { $0.slot == slot }
        let kcal = items.reduce(0) { $0 + $1.nutrients.kcal }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(slot.title, systemImage: slot.icon).font(.headline)
                Spacer()
                if kcal > 0 { Text("\(kcal.it()) kcal").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
                // one tap: photo of the plate or of the pack (barcode and name are read too), or scan the barcode
                Button { app.sheet = .addFood(slot, .photo) } label: {
                    Image(systemName: "camera.fill").font(.title3)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Foto per \(slot.title)")
                .accessibilityIdentifier("meal-photo-\(slot.rawValue)")
                Button { app.sheet = .addFood(slot, .barcode) } label: {
                    Image(systemName: "barcode.viewfinder").font(.title3)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Codice a barre per \(slot.title)")
                .accessibilityIdentifier("meal-barcode-\(slot.rawValue)")
                Menu {
                    Button { app.sheet = .addFood(slot, .search) } label: { Label("Cerca alimento", systemImage: "magnifyingglass") }
                    Button { app.sheet = .addFood(slot, .describe) } label: { Label("Descrivi a voce o per iscritto", systemImage: "text.bubble") }
                    Button { app.sheet = .addFood(slot, .barcode) } label: { Label("Codice a barre", systemImage: "barcode.viewfinder") }
                    Button { app.sheet = .addFood(slot, .text) } label: { Label("Leggi il nome dalla confezione", systemImage: "text.viewfinder") }
                    Button { app.sheet = .addFood(slot, .label) } label: { Label("Foto dell'etichetta", systemImage: "doc.text.viewfinder") }
                    Button { app.sheet = .addFood(slot, .photo) } label: { Label("Foto del piatto", systemImage: "camera") }
                    Button { app.sheet = .addFood(slot, .manual) } label: { Label("Inserisci a mano", systemImage: "square.and.pencil") }
                    if !items.isEmpty {
                        Divider()
                        Button { Sync.saveMeal(items, slot: slot, context: context) } label: { Label("Salva in Ripeti", systemImage: "star") }
                    }
                } label: { Image(systemName: "plus.circle").font(.title3) }
                .accessibilityLabel("Altri modi per aggiungere a \(slot.title)")
            }
            if items.isEmpty { quickLog(slot) }
            ForEach(items) { entry in
                EntryRow(entry: entry)
                    .contextMenu {
                        ForEach(MealSlot.allCases.filter { $0 != slot }) { other in
                            Button("Sposta in \(other.title)") { entry.slot = other }
                        }
                        Button("Duplica") {
                            context.insert(FoodEntry(day: app.day, slot: slot, name: entry.name, grams: entry.grams, per100: entry.per100))
                        }
                        Button("Elimina", role: .destructive) { withAnimation { context.delete(entry) } }
                    }
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    /// An empty meal can be filled in one tap: the same as yesterday, or a size estimate.
    private func quickLog(_ slot: MealSlot) -> some View {
        let yesterday = entries.filter { $0.day == DayId.shift(app.day, by: -1) && $0.slot == slot }
        let yesterdayKcal = yesterday.reduce(0) { $0 + $1.nutrients.kcal }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Niente ancora · segnalo in un tocco").font(.subheadline).foregroundStyle(.tertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if !yesterday.isEmpty {
                        Button("Come ieri · \(yesterdayKcal.it())") {
                            withAnimation {
                                for e in yesterday {
                                    context.insert(FoodEntry(day: app.day, slot: slot, name: e.name, grams: e.grams, per100: e.per100))
                                }
                            }
                        }
                        .accessibilityIdentifier("quick-yesterday-\(slot.rawValue)")
                    }
                    ForEach(QuickLog.Size.allCases, id: \.self) { size in
                        let estimate = QuickLog.estimate(slot, size, goals: goals)
                        Button("\(size.title) · \(estimate.kcal.it())") {
                            withAnimation {
                                context.insert(FoodEntry(day: app.day, slot: slot, name: QuickLog.name(slot, size), grams: 100, per100: estimate))
                            }
                        }
                        .accessibilityIdentifier("quick-\(size.rawValue)-\(slot.rawValue)")
                    }
                }
                .font(.footnote)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var weightRow: some View {
        let today = weights.first { $0.day == app.day }
        return Button { app.sheet = .weight(.type) } label: {
            HStack {
                Image(systemName: "scalemass.fill").foregroundStyle(.blue)
                Text(today.map { "Peso: \($0.kg.it(1)) kg" } ?? "Registra il peso di oggi")
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}

struct EntryRow: View {
    @Bindable var entry: FoodEntry
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            HStack(spacing: 12) {
                if let data = entry.photo, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.subheadline).lineLimit(2)
                    Text("\(entry.grams.it()) g · P \(entry.nutrients.protein.it()) · C \(entry.nutrients.carbs.it()) · G \(entry.nutrients.fat.it())")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(entry.nutrients.kcal.it())").font(.subheadline.monospacedDigit().weight(.semibold))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $editing) {
            AmountSheet(name: entry.name, per100: entry.per100, grams: entry.grams, portions: []) { grams in
                entry.grams = grams
            }
            .presentationDetents([.medium])
        }
    }
}

/// Animated rings for calories and macros.
struct RingsCard: View {
    var totals: Nutrients
    var goals: Goals
    var big: Bool

    var body: some View {
        HStack(spacing: 20) {
            ZStack {
                Ring(progress: totals.kcal / max(goals.kcal, 1), color: Theme.accent, width: big ? 20 : 16)
                VStack(spacing: 0) {
                    Text(max(goals.kcal - totals.kcal, 0).it())
                        .font(.system(size: big ? 34 : 28, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text(totals.kcal > goals.kcal ? "oltre di \((totals.kcal - goals.kcal).it())" : "kcal rimaste")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: big ? 170 : 140, height: big ? 170 : 140)
            VStack(alignment: .leading, spacing: 12) {
                MacroBar(name: "Proteine", value: totals.protein, goal: goals.protein, color: .pink)
                MacroBar(name: "Carboidrati", value: totals.carbs, goal: goals.carbs, color: .orange)
                MacroBar(name: "Grassi", value: totals.fat, goal: goals.fat, color: .yellow)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22))
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: totals)
    }
}

struct Ring: View {
    var progress: Double
    var color: Color
    var width: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: width)
            Circle()
                .trim(from: 0, to: min(progress, 1))
                .stroke(AngularGradient(colors: [color.opacity(0.7), color], center: .center),
                        style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if progress > 1 {
                Circle()
                    .trim(from: 0, to: min(progress - 1, 1))
                    .stroke(Color.red.opacity(0.8), style: StrokeStyle(lineWidth: width * 0.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

struct MacroBar: View {
    var name: String
    var value: Double
    var goal: Double
    var color: Color
    var unit = "g"
    var digits = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.caption.weight(.semibold))
                Spacer()
                Text("\(value.it(digits)) / \(goal.it(digits)) \(unit)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.15))
                    Capsule().fill(color).frame(width: geo.size.width * min(value / max(goal, 1), 1))
                }
            }
            .frame(height: 8)
        }
    }
}

struct MicronutrientsCard: View {
    var totals: Nutrients
    var goals: Goals
    var vegetarian: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Micronutrienti").font(.headline)
                if vegetarian { Text("vegetariano").font(.caption).padding(.horizontal, 8).padding(.vertical, 2).background(.green.opacity(0.15), in: Capsule()) }
            }
            row("Fibre", totals.fiber, goals.fiber, "g", .brown)
            row("Ferro", totals.iron, goals.iron, "mg", .red)
            row("Calcio", totals.calcium, goals.calcium, "mg", .blue)
            row("Zinco", totals.zinc, goals.zinc, "mg", .purple)
            row("Vitamina B12", totals.b12, goals.b12, "µg", .teal)
            if vegetarian && totals.iron < goals.iron * 0.6 {
                Text("Ferro basso: abbina legumi o verdure a foglia con vitamina C (agrumi, peperoni, kiwi) per assorbirne di più.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if vegetarian {
                Text("La B12 da cibi vegetariani è spesso insufficiente: parlane con il medico per un integratore.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private func row(_ name: String, _ value: Double, _ goal: Double, _ unit: String, _ color: Color) -> some View {
        MacroBar(name: name, value: value, goal: goal, color: color, unit: unit, digits: unit == "µg" ? 1 : 0)
    }
}

struct BigButton: View {
    var title: String
    var icon: String
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title)
                Text(title).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 90)
            .foregroundStyle(.white)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }
}

enum Theme {
    static let accent = Color(red: 0.30, green: 0.72, blue: 0.50)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
}
