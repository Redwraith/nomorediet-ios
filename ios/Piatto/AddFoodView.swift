import SwiftData
import SwiftUI

/// Adds foods to a meal: search (built-in list, own foods, Open Food Facts), product name read from the pack, barcode,
/// nutrition label photo, plate or pack photo (barcode and printed name are read too) or manual values.
struct AddFoodView: View {
    enum Mode: String { case search, barcode, text, label, photo, manual, describe }

    @State var slot: MealSlot
    @State var mode: Mode
    @EnvironmentObject private var app: AppState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \CustomFood.createdAt, order: .reverse) private var customFoods: [CustomFood]
    @Query(sort: \FoodEntry.createdAt, order: .reverse) private var history: [FoodEntry]

    @State private var query = ""
    @State private var online: [Food] = []
    @State private var databaseResults: [Food] = []
    @State private var searching = false
    @State private var picked: Food?
    @State private var photo: UIImage?
    @State private var showCamera = false
    @State private var cameraPurpose = Mode.photo
    @State private var message: String?
    @State private var manual = ManualFood()
    @State private var volumeMl: Double?
    @State private var added: [String] = []
    @State private var searchTask: Task<Void, Never>?
    /// Word blocks tapped in the text reader (brand, product name), in tap order.
    @State private var scannedWords: [String] = []
    @State private var aiResult: FoodAI.Result?
    @State private var aiItems: [AIRow] = []
    @State private var analyzing = false
    @State private var mealText = ""
    @State private var listening = false
    /// The last photo was refused as "not food": the user can override.
    @State private var canForce = false
    /// Product name and type printed on the pack in the last photo.
    @State private var packaging: [String] = []
    /// Grams on a kitchen scale in the last photo.
    @State private var scaleGrams: Double?

    struct AIRow: Identifiable {
        var item: FoodAI.Item
        var grams: Double
        var include = true
        var id: UUID { item.id }
    }

    struct ManualFood {
        var name = ""
        var barcode: String?
        var kcal = ""
        var protein = ""
        var carbs = ""
        var fat = ""
        var fiber = ""
        var portion = "100"
    }

    private var ownFoods: [Food] {
        customFoods.map { Food(name: $0.name, per100: $0.per100, portion: $0.portion, portionName: "1 porzione", barcode: $0.barcode, source: .custom) }
    }

    /// Foods eaten recently, most recent first, one per name.
    private var recent: [Food] {
        var seen = Set<String>()
        return history.compactMap { e -> Food? in
            guard seen.insert(e.name).inserted else { return nil }
            return Food(name: e.name, per100: e.per100, portion: e.grams, portionName: "come l'ultima volta", source: .custom)
        }.prefix(15).map { $0 }
    }

    var body: some View {
        NavigationStack {
            List {
                if let photo { photoHeader(photo) }
                if analyzing {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(AIGuard.shared.settings.engine == .apple ? "Analizzo la foto sull'iPhone…" : "Claude sta analizzando la foto…").foregroundStyle(.secondary)
                    }
                }
                if !aiItems.isEmpty { aiSection }
                if let volumeMl { volumeHeader(volumeMl) }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                if canForce, let photo {
                    Button { Task { await analyze(photo, force: true) } } label: {
                        Label("È cibo, analizza comunque", systemImage: "fork.knife")
                    }
                }
                if !added.isEmpty {
                    Section("Aggiunti a \(slot.title)") {
                        ForEach(added, id: \.self) { Label($0, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                    }
                }
                switch mode {
                case .manual: manualForm
                case .describe: describeSection
                default: searchSections
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Cerca: pasta, yogurt greco, ceci…")
            .onChange(of: query) { _, text in scheduleOnlineSearch(text) }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // the meal is chosen from the time of day; tap the title to change it
                ToolbarItem(placement: .principal) {
                    Menu {
                        Picker("Pasto", selection: $slot) {
                            ForEach(MealSlot.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: slot.icon)
                            Text(slot.title).font(.headline)
                            Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(.primary)
                    }
                    .accessibilityLabel("Pasto: \(slot.title). Tocca per cambiare")
                }
                ToolbarItem(placement: .cancellationAction) { Button(added.isEmpty ? "Annulla" : "Fine") { dismiss() } }
                ToolbarItem(placement: .bottomBar) { toolsBar }
            }
            .sheet(item: $picked) { food in
                AmountSheet(name: food.name, per100: food.per100, grams: suggestedGrams(food),
                            portions: [(food.portionName, food.portion), ("100 g", 100)]) { grams in
                    add(food, grams: grams)
                }
                .presentationDetents([.medium, .large])
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    showCamera = false
                    guard let image else { return }
                    Task { await handle(image) }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: Binding(get: { mode == .barcode && picked == nil && message == nil }, set: { if !$0 { mode = .search } })) {
                barcodeSheet
            }
            .sheet(isPresented: Binding(get: { mode == .text }, set: { if !$0 { mode = .search } })) {
                textSheet
            }
            .onAppear(perform: start)
        }
    }

    private func start() {
        switch mode {
        case .photo, .label:
            cameraPurpose = mode
            showCamera = true
            mode = .search
        default: break
        }
    }

    // MARK: Search

    @ViewBuilder private var searchSections: some View {
        let local = FoodDatabase.search(query, extra: ownFoods)
        if query.isEmpty {
            if !recent.isEmpty {
                Section("Recenti") { ForEach(recent) { foodRow($0) } }
            }
            if !ownFoods.isEmpty {
                Section("I miei alimenti") { ForEach(ownFoods) { foodRow($0) } }
            }
            // the whole built-in list, alphabetical: browse it or type to search the large database
            Section("Elenco alimenti · \(FoodDatabase.foods.count)") {
                ForEach(FoodDatabase.foods.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }) { foodRow($0) }
            }
        } else {
            if !local.isEmpty { Section("Alimenti") { ForEach(local.prefix(30)) { foodRow($0) } } }
            if !databaseResults.isEmpty {
                Section("Database · \(FoodStore.shared.count.formatted()) alimenti") { ForEach(databaseResults) { foodRow($0) } }
            }
            Section {
                if searching { HStack { ProgressView(); Text("Cerco su Open Food Facts…").foregroundStyle(.secondary) } }
                ForEach(online) { foodRow($0) }
                if !searching && online.isEmpty && query.count >= 3 {
                    Text("Nessun prodotto confezionato trovato.").foregroundStyle(.secondary)
                }
                Button { manual.name = query; mode = .manual } label: { Label("Crea \"\(query)\" a mano", systemImage: "square.and.pencil") }
            } header: { Text("Prodotti confezionati") }
        }
    }

    private func foodRow(_ food: Food) -> some View {
        Button { picked = food } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(food.name).foregroundStyle(.primary)
                    Text([food.brand, "\(food.per100.kcal.it()) kcal · P \(food.per100.protein.it(1)) g per 100 g"].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent)
            }
        }
    }

    private func scheduleOnlineSearch(_ text: String) {
        searchTask?.cancel()
        online = []
        databaseResults = []
        guard text.count >= 3 else { searching = false; return }
        searching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let fromDatabase = await Task.detached(priority: .userInitiated) { FoodStore.shared.search(text) }.value
            guard !Task.isCancelled else { return }
            databaseResults = fromDatabase
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = (try? await OpenFoodFacts.search(text)) ?? []
            guard !Task.isCancelled else { return }
            online = found
            searching = false
        }
    }

    private var toolsBar: some View {
        HStack {
            Button { mode = .barcode; message = nil } label: { Label("Codice", systemImage: "barcode.viewfinder") }
            Spacer()
            Button { scannedWords = []; mode = .text; message = nil } label: { Label("Leggi il nome", systemImage: "text.viewfinder") }
                .accessibilityIdentifier("scan-text")
            Spacer()
            Button { cameraPurpose = .label; showCamera = true } label: { Label("Etichetta", systemImage: "doc.text.viewfinder") }
            Spacer()
            Button { cameraPurpose = .photo; showCamera = true } label: { Label("Foto", systemImage: "camera") }
            Spacer()
            Button { mode = .describe; message = nil } label: { Label("Descrivi", systemImage: "text.bubble") }
            Spacer()
            Button { mode = .manual } label: { Label("A mano", systemImage: "square.and.pencil") }
        }
        .labelStyle(.iconOnly)
        .font(.title3)
    }

    // MARK: Product name from the pack

    /// Point the camera at the pack, tap the brand and the product name, then search them
    /// in the built-in list, the database and Open Food Facts (which give the product's real name).
    private var textSheet: some View {
        NavigationStack {
            Group {
                if TextScanner.isAvailable {
                    TextScanner { text in
                        let words = TextReader.productQuery(text)
                        if !words.isEmpty && !scannedWords.contains(words) { scannedWords.append(words) }
                    }
                    .ignoresSafeArea()
                } else {
                    ContentUnavailableView("Lettura non disponibile", systemImage: "text.viewfinder",
                                           description: Text("Consenti la fotocamera in Impostazioni → Nomorediet."))
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Text(scannedWords.isEmpty ? "Tocca la marca e il nome del prodotto sulla confezione" : scannedWords.joined(separator: " "))
                        .font(scannedWords.isEmpty ? .footnote : .headline)
                        .foregroundStyle(scannedWords.isEmpty ? .secondary : .primary)
                        .multilineTextAlignment(.center)
                    HStack {
                        Button("Cancella") { scannedWords = [] }.buttonStyle(.bordered).disabled(scannedWords.isEmpty)
                        Button {
                            query = scannedWords.joined(separator: " ")
                            scannedWords = []
                            mode = .search
                        } label: { Label("Cerca", systemImage: "magnifyingglass").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent).disabled(scannedWords.isEmpty)
                            .accessibilityIdentifier("scan-text-search")
                    }
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("Leggi il nome del prodotto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { mode = .search } } }
        }
    }

    // MARK: Barcode

    private var barcodeSheet: some View {
        NavigationStack {
            Group {
                if BarcodeScanner.isAvailable {
                    BarcodeScanner { code in Task { await lookUp(barcode: code) } }
                        .ignoresSafeArea()
                } else {
                    ContentUnavailableView("Scanner non disponibile", systemImage: "barcode.viewfinder",
                                           description: Text("Consenti la fotocamera in Impostazioni → Nomorediet."))
                }
            }
            .navigationTitle("Inquadra il codice a barre")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { mode = .search } } }
        }
    }

    private func lookUp(barcode: String) async {
        if let own = customFoods.first(where: { $0.barcode == barcode }) {
            mode = .search
            picked = Food(name: own.name, per100: own.per100, portion: own.portion, portionName: "1 porzione", barcode: barcode, source: .custom)
            return
        }
        // weekly database first: works offline
        if let food = await Task.detached(priority: .userInitiated, operation: { FoodStore.shared.product(barcode: barcode) }).value {
            mode = .search
            picked = food
            return
        }
        do {
            if let food = try await OpenFoodFacts.product(barcode: barcode) {
                FoodStore.shared.upsert([food])
                mode = .search
                picked = food
            } else {
                manual = ManualFood(barcode: barcode)
                message = "Prodotto \(barcode) non trovato: fotografa l'etichetta o inserisci i valori a mano. La prossima volta lo riconosco."
                mode = .manual
            }
        } catch {
            message = "Senza connessione non posso cercare il codice \(barcode). Inserisci i valori a mano."
            manual = ManualFood(barcode: barcode)
            mode = .manual
        }
    }

    // MARK: Photos

    private func handle(_ image: UIImage) async {
        switch cameraPurpose {
        case .label:
            message = "Leggo l'etichetta…"
            let lines = await TextReader.lines(in: image)
            let n = TextReader.label(lines)
            manual.kcal = n.kcal > 0 ? n.kcal.it(0) : ""
            manual.protein = n.protein > 0 ? n.protein.it(1) : ""
            manual.carbs = n.carbs > 0 ? n.carbs.it(1) : ""
            manual.fat = n.fat > 0 ? n.fat.it(1) : ""
            manual.fiber = n.fiber > 0 ? n.fiber.it(1) : ""
            message = n.kcal > 0 ? "Ho letto i valori per 100 g: controllali e dai un nome al prodotto." : "Non riesco a leggere l'etichetta: inserisci i valori a mano."
            mode = .manual
        default:
            photo = image
            // a pack in the photo: the barcode is the most precise answer, then the printed product name
            message = "Cerco codice a barre e nome del prodotto…"
            let pack = await PackageReader.read(image)
            if let code = pack.barcode {
                message = "Codice a barre letto: \(code)"
                await lookUp(barcode: code)
                return
            }
            packaging = pack.lines
            scaleGrams = pack.scaleGrams
            if FoodAI.isReady {
                message = pack.lines.isEmpty ? nil : "Sulla confezione: \(pack.lines.prefix(2).joined(separator: " · "))"
                await analyze(image, force: PackageReader.namesFood(pack.lines))
            } else if let name = pack.lines.first {
                query = name
                message = "Sulla confezione leggo \"\(name)\": ecco i risultati. Per il riconoscimento del piatto attiva l'analisi AI in Profilo."
            } else {
                message = "Foto salvata con il pasto. Cerca gli alimenti nel piatto, oppure attiva l'analisi AI in Profilo → Analisi AI."
            }
        }
    }

    private func analyze(_ image: UIImage?, text: String = "", force: Bool = false) async {
        analyzing = true
        aiItems = []
        message = nil
        canForce = false
        defer { analyzing = false }
        do {
            let input = MealRecognizer.Input(image: image, text: text.isEmpty ? query : text, volumeMl: volumeMl,
                                             packaging: image == nil ? [] : packaging, scaleGrams: image == nil ? nil : scaleGrams, force: force)
            let result = try await MealRecognizer.recognize(input, foods: ownFoods + FoodDatabase.foods)
            aiResult = result
            withAnimation(.snappy) { aiItems = result.items.map { AIRow(item: $0, grams: $0.grams) } }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if case FoodAI.Failure.notFood = error { canForce = !force; UINotificationFeedbackGenerator().notificationOccurred(.warning) }
            DebugLog.shared.add("error", "ai", message ?? "")
        }
    }

    @ViewBuilder private var aiSection: some View {
        Section {
            ForEach($aiItems) { $row in
                HStack(spacing: 10) {
                    Button { row.include.toggle() } label: {
                        Image(systemName: row.include ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(row.include ? Theme.accent : .secondary).font(.title3)
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.item.name)
                        if !row.item.detail.isEmpty && row.item.detail != row.item.name {
                            Text(row.item.detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        let n = row.item.per100.scaled(row.grams / 100)
                        Text("\(n.kcal.it()) kcal · P \(n.protein.it()) · C \(n.carbs.it()) · G \(n.fat.it())\(row.item.fromTable ? " · da tabella" : " · stima AI")\(row.item.confidence == "bassa" ? " · incerta" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    TextField("g", value: $row.grams, format: .number.precision(.fractionLength(0)))
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 56)
                        .textFieldStyle(.roundedBorder)
                    Text("g").foregroundStyle(.secondary)
                }
            }
            if let note = aiResult?.note, !note.isEmpty {
                Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                addAIItems()
            } label: {
                let kcal = aiItems.filter(\.include).reduce(0) { $0 + $1.item.per100.kcal * $1.grams / 100 }
                Label("Aggiungi selezionati · \(kcal.it()) kcal", systemImage: "plus.circle.fill").font(.headline)
            }
            .disabled(!aiItems.contains(where: \.include))
            .accessibilityIdentifier("ai-add-selected")
        } header: {
            Text(aiResult.map { "Analisi AI · \($0.dish)" } ?? "Analisi AI")
        } footer: {
            Text("Correggi i grammi se servono: Nomorediet ricorda le correzioni e le usa per le prossime foto.")
        }
    }

    private func addAIItems() {
        for row in aiItems where row.include {
            FoodAI.Corrections.add(name: row.item.name, estimated: row.item.grams, actual: row.grams)
            add(Food(name: row.item.name, per100: row.item.per100, portion: row.grams, portionName: "dall'analisi", source: .custom), grams: row.grams)
        }
        withAnimation { aiItems = [] }
    }

    // MARK: Describe (text or voice)

    @ViewBuilder private var describeSection: some View {
        Section {
            TextField("Es. 80 g di pasta al pesto, un'insalata con olio e 2 uova", text: $mealText, axis: .vertical)
                .lineLimit(3...6)
                .accessibilityIdentifier("describe-text")
            Button {} label: {
                Label(listening ? "Ti ascolto… rilascia per finire" : "Tieni premuto e racconta cosa hai mangiato",
                      systemImage: listening ? "waveform" : "mic.fill")
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !listening { startListening() } }
                .onEnded { _ in stopListening() })
            Button {
                Task { await analyze(nil, text: mealText) }
            } label: {
                Label("Analizza", systemImage: "sparkles").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(mealText.trimmingCharacters(in: .whitespaces).count < 3 || analyzing)
            .accessibilityIdentifier("describe-analyze")
        } header: { Text("Descrivi il pasto") } footer: {
            Text(FoodAI.isReady
                 ? "L'AI riconosce gli alimenti e le quantità; calorie e nutrienti vengono dalla tabella di Nomorediet quando l'alimento c'è."
                 : "Senza un motore AI attivo uso il riconoscimento semplice: scrivi quantità e alimenti, per esempio \"200 g di riso, 2 uova\".")
        }
    }

    private func startListening() {
        listening = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        SpeechListener.shared.start { error in
            if let error { message = error; listening = false }
        }
    }

    private func stopListening() {
        guard listening else { return }
        listening = false
        SpeechListener.shared.stop { said in
            guard !said.isEmpty else { message = "Non ho sentito nulla, riprova."; return }
            mealText = mealText.isEmpty ? said : mealText + ", " + said
            Task { await analyze(nil, text: mealText) }
        }
    }

    private func photoHeader(_ image: UIImage) -> some View {
        Image(uiImage: image).resizable().scaledToFill().frame(height: 180).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .listRowInsets(EdgeInsets())
    }

    private func volumeHeader(_ ml: Double) -> some View {
        Label("Volume misurato: \(ml.it()) ml", systemImage: "cube.transparent").foregroundStyle(Theme.accent)
    }

    /// With a measured volume, grams = volume × density of the food.
    private func suggestedGrams(_ food: Food) -> Double {
        guard let volumeMl else { return food.portion }
        return (volumeMl * density(food)).rounded()
    }

    private func density(_ food: Food) -> Double {
        let n = FoodDatabase.normalize(food.name)
        if ["insalata", "rucola", "spinaci", "cavolo"].contains(where: n.contains) { return 0.25 }
        if ["pasta", "riso", "farro", "orzo", "couscous", "quinoa"].contains(where: n.contains) { return 0.65 }
        if ["zuppa", "minestrone", "passata", "yogurt", "latte"].contains(where: n.contains) { return 1.0 }
        return 0.8
    }

    // MARK: Manual

    @ViewBuilder private var manualForm: some View {
        Section("Prodotto") {
            TextField("Nome", text: $manual.name)
            if let code = manual.barcode { LabeledContent("Codice a barre", value: code) }
        }
        Section("Valori per 100 g") {
            number("Calorie (kcal)", $manual.kcal)
            number("Proteine (g)", $manual.protein)
            number("Carboidrati (g)", $manual.carbs)
            number("Grassi (g)", $manual.fat)
            number("Fibre (g)", $manual.fiber)
        }
        Section("Porzione abituale") { number("Grammi", $manual.portion) }
        Section {
            Button("Salva e aggiungi") {
                let per100 = Nutrients(kcal: manual.kcal.italianDouble ?? 0, protein: manual.protein.italianDouble ?? 0,
                                       carbs: manual.carbs.italianDouble ?? 0, fat: manual.fat.italianDouble ?? 0,
                                       fiber: manual.fiber.italianDouble ?? 0)
                let portion = manual.portion.italianDouble ?? 100
                let name = manual.name.trimmingCharacters(in: .whitespaces)
                context.insert(CustomFood(name: name, barcode: manual.barcode, per100: per100, portion: portion))
                picked = Food(name: name, per100: per100, portion: portion, portionName: "1 porzione", barcode: manual.barcode, source: .custom)
                manual = ManualFood()
                mode = .search
            }
            .disabled(manual.name.trimmingCharacters(in: .whitespaces).isEmpty || (manual.kcal.italianDouble ?? 0) <= 0)
        }
    }

    private func number(_ title: String, _ value: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField("0", text: value).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 120)
        }
    }

    // MARK: Save

    private func add(_ food: Food, grams: Double) {
        let isFirst = added.isEmpty
        context.insert(FoodEntry(day: app.day, slot: slot, name: food.brand.map { "\(food.name) (\($0))" } ?? food.name,
                                 grams: grams, per100: food.per100, photo: isFirst ? photo?.thumbnailJPEG() : nil))
        if food.source == .openFoodFacts, !customFoods.contains(where: { $0.barcode != nil && $0.barcode == food.barcode }) {
            context.insert(CustomFood(name: food.name, barcode: food.barcode, per100: food.per100, portion: food.portion))
        }
        withAnimation { added.append("\(food.name) · \(grams.it()) g") }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        query = ""
        Sync.afterFoodChange(context: context, day: app.day)
        Hero.award(.food)
    }
}

/// Grams picker with quick portions and a live preview of the nutrients.
struct AmountSheet: View {
    var name: String
    var per100: Nutrients
    @State var grams: Double
    var portions: [(String, Double)]
    var save: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Grammi", text: $text).keyboardType(.decimalPad).font(.largeTitle.weight(.bold)).monospacedDigit()
                            .onChange(of: text) { _, t in if let g = t.italianDouble { grams = g } }
                        Text("g").font(.title2).foregroundStyle(.secondary)
                    }
                    Stepper("± 10 g", value: Binding(get: { grams }, set: { grams = max(0, $0); text = grams.it() }), step: 10)
                    if !portions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(portions.indices, id: \.self) { i in
                                    let p = portions[i]
                                    Button("\(p.0) · \(p.1.it()) g") { grams = p.1; text = p.1.it() }.buttonStyle(.bordered)
                                }
                                Button("½") { grams = (grams / 2).rounded(); text = grams.it() }.buttonStyle(.bordered)
                                Button("×2") { grams *= 2; text = grams.it() }.buttonStyle(.bordered)
                            }
                        }
                    }
                }
                Section("Per \(grams.it()) g") {
                    let n = per100.scaled(grams / 100)
                    LabeledContent("Calorie", value: "\(n.kcal.it()) kcal")
                    LabeledContent("Proteine", value: "\(n.protein.it(1)) g")
                    LabeledContent("Carboidrati", value: "\(n.carbs.it(1)) g")
                    LabeledContent("Grassi", value: "\(n.fat.it(1)) g")
                    if n.fiber > 0 { LabeledContent("Fibre", value: "\(n.fiber.it(1)) g") }
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Aggiungi") { save(grams); dismiss() }.disabled(grams <= 0)
                }
            }
            .onAppear { text = grams.it() }
        }
    }
}

