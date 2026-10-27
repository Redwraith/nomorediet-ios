import SwiftData
import SwiftUI

struct ProfileTab: View {
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var app: AppState
    @Environment(\.modelContext) private var context
    @State private var manualText = ""
    @State private var dbUpdated = FoodStore.shared.updatedCount
    @State private var dbUpdating = false
    @ObservedObject private var updates = UpdateChecker.shared
    @State private var checking = false
    @State private var apiKey = ""
    @State private var hasKey = FoodAI.hasKey
    @State private var keyStatus: String?
    @State private var geminiKey = ""
    @State private var geminiReady = GeminiAI.isReady
    @State private var geminiStatus: String?
    @ObservedObject private var ai = AIGuard.shared
    @Environment(\.scenePhase) private var scenePhase
    /// Waiting to come back from Google / Anthropic with a key copied: it is picked up and checked by itself.
    @State private var waitingForKey: AIGuard.Engine?
    @State private var compatibleKey = ""
    @State private var compatibleStatus: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                ProfileFields(profile: $store.profile)
                Section {
                    Picker("Tipo di dieta", selection: $store.profile.diet) {
                        ForEach(Profile.Diet.allCases) { Text($0.title).tag($0) }
                    }
                    Text(store.profile.diet.summary).font(.footnote).foregroundStyle(.secondary)
                    WeekdayPicker(selection: $store.profile.trainingWeekdaySet)
                } header: { Text("Dieta e giorni di allenamento") } footer: {
                    Text("I giorni scelti sono giorni di allenamento per calorie, carboidrati e promemoria della creatina. Se ti alleni in un altro giorno, l'app lo capisce quando registri una serie.")
                }
                Section {
                    let train = Nutrition.goals(store.profile, kind: .training)
                    let rest = Nutrition.goals(store.profile, kind: .rest)
                    LabeledContent("Mantenimento", value: "\(Nutrition.maintenance(store.profile).it()) kcal")
                    LabeledContent("Obiettivo medio", value: "\(Nutrition.dailyTarget(store.profile).it()) kcal")
                    LabeledContent("Giorno di allenamento", value: "\(train.kcal.it()) kcal · C \(train.carbs.it()) g")
                    LabeledContent("Giorno di riposo", value: "\(rest.kcal.it()) kcal · C \(rest.carbs.it()) g")
                    LabeledContent("Proteine e grassi", value: "P \(train.protein.it()) g · G \(train.fat.it()) g")
                    HStack {
                        TextField("Calorie fisse (facoltativo)", text: $manualText).keyboardType(.numberPad)
                        if store.profile.manualKcal != nil {
                            Button("Usa il calcolo") { store.profile.manualKcal = nil; manualText = "" }.font(.caption)
                        }
                    }
                    .onSubmit { store.profile.manualKcal = manualText.italianDouble }
                    .onChange(of: manualText) { _, t in store.profile.manualKcal = t.isEmpty ? nil : t.italianDouble }
                } header: { Text("Obiettivi") } footer: {
                    Text("I giorni di allenamento hanno più carboidrati e quelli di riposo meno, con la stessa media settimanale. Dopo 2 settimane di dati il mantenimento si adatta da solo.")
                }
                Section {
                    Toggle("Scelta automatica del motore", isOn: $ai.settings.auto)
                    if ai.settings.auto {
                        Text(AIRouter.summary()).font(.footnote).foregroundStyle(.secondary)
                        Text("Per ogni compito uso il motore gratuito migliore tra quelli collegati e passo al successivo se uno non risponde. Claude e DeepSeek, a pagamento, si usano solo scegliendoli a mano.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Picker(ai.settings.auto ? "Collega un motore" : "Motore", selection: $ai.settings.engine) {
                        Text("Groq (gratis, velocissimo, testo e foto)").tag(AIGuard.Engine.groq)
                        Text("GLM di Z.ai (gratis, testo e foto)").tag(AIGuard.Engine.glm)
                        Text("Gemini (gratis, chiave Google)").tag(AIGuard.Engine.gemini)
                        Text("DeepSeek (pochi centesimi, solo testo)").tag(AIGuard.Engine.deepseek)
                        Text("Apple, sull'iPhone (gratis)").tag(AIGuard.Engine.apple)
                        Text("Claude (chiave API)").tag(AIGuard.Engine.claude)
                    }
                    if ai.settings.engine == .apple {
                        if let reason = OnDeviceAI.unavailableReason {
                            Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        } else {
                            Label("Pronto: la foto resta sull'iPhone", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.accent)
                        }
                    } else if ai.settings.engine == .gemini {
                        if geminiReady {
                            Label("Gemini collegato", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.accent)
                            Button("Scollega Gemini", role: .destructive) {
                                Keychain.delete(Keychain.gemini); geminiReady = false; geminiStatus = nil
                            }
                        } else {
                            Button {
                                waitingForKey = .gemini
                                UIApplication.shared.open(GeminiAI.keyPage)
                            } label: { Label("Accedi con Google e collega Gemini", systemImage: "person.badge.key.fill") }
                                .accessibilityIdentifier("gemini-login")
                            Text("Entri con il tuo account Google, premi \"Create API key\" e poi \"Copy\". Torna qui: la chiave viene presa e collegata da sola, una volta per sempre.")
                                .font(.footnote).foregroundStyle(.secondary)
                            DisclosureGroup("Incolla a mano") {
                                SecureField("Chiave Gemini (AIza…)", text: $geminiKey)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                Button("Collega") { connectGemini(geminiKey) }.disabled(geminiKey.count < 20)
                            }
                            .font(.footnote)
                        }
                        if let geminiStatus { Text(geminiStatus).font(.footnote).foregroundStyle(.secondary) }
                    } else if let provider = OpenAICompatibleAI.provider(ai.settings.engine) {
                        if OpenAICompatibleAI.hasKey(provider) && compatibleStatus[provider.name] != "scollegato" {
                            Label("\(provider.name) collegato", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.accent)
                            Button("Scollega \(provider.name)", role: .destructive) {
                                Keychain.delete(provider.keyService); compatibleStatus[provider.name] = "scollegato"
                            }
                        } else {
                            Button {
                                waitingForKey = provider.engine
                                UIApplication.shared.open(provider.keyPage)
                            } label: { Label("Accedi a \(provider.name) e collega la chiave", systemImage: "person.badge.key.fill") }
                                .accessibilityIdentifier("compatible-login")
                            Text(provider.engine == .glm
                                 ? "Entri su z.ai (anche con Google), premi \"Create API Key\" e copiala. Tornando qui viene collegata da sola."
                                 : provider.engine == .groq
                                 ? "Entri su console.groq.com (anche con Google), premi \"Create API Key\" e copiala. Tornando qui viene collegata da sola."
                                 : "Entri su platform.deepseek.com, crei una chiave e la copi. Tornando qui viene collegata da sola.")
                                .font(.footnote).foregroundStyle(.secondary)
                            DisclosureGroup("Incolla a mano") {
                                SecureField("Chiave \(provider.name)", text: $compatibleKey)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                Button("Collega") { connectCompatible(compatibleKey, provider) }.disabled(compatibleKey.count < 20)
                            }
                            .font(.footnote)
                        }
                        if let status = compatibleStatus[provider.name], status != "scollegato" { Text(status).font(.footnote).foregroundStyle(.secondary) }
                    } else if hasKey {
                        Label("Analisi con Claude attiva", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.accent)
                        Button("Prova la chiave") {
                            keyStatus = "Controllo…"
                            Task { keyStatus = await FoodAI.test(key: Keychain.read() ?? "") }
                        }
                        Button("Rimuovi la chiave", role: .destructive) { Keychain.delete(); hasKey = false; keyStatus = nil }
                    } else {
                        SecureField("Chiave API (sk-ant-…)", text: $apiKey)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Salva chiave") {
                            let key = apiKey
                            keyStatus = "Controllo…"
                            Task {
                                let result = await FoodAI.test(key: key)
                                keyStatus = result
                                if result.hasSuffix("✓") { Keychain.save(key); hasKey = true; apiKey = "" }
                            }
                        }
                        .disabled(!apiKey.hasPrefix("sk-ant-"))
                        Button {
                            waitingForKey = .claude
                            UIApplication.shared.open(URL(string: "https://console.anthropic.com/settings/keys")!)
                        } label: { Label("Accedi ad Anthropic e collega Claude", systemImage: "person.badge.key.fill") }
                        Text("Crea una chiave e copiala: tornando qui viene collegata da sola.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let keyStatus, ai.settings.engine == .claude { Text(keyStatus).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Analisi AI") } footer: {
                    Text(ai.settings.engine == .glm
                         ? "GLM di Z.ai è gratuito (modelli Flash, con limiti di velocità): riconosce il cibo da testo, voce e foto. La chiave si crea su z.ai e resta nel portachiavi; testo e foto vanno ai server di Z.ai."
                         : ai.settings.engine == .groq
                         ? "Groq è gratuito entro i limiti giornalieri e risponde in pochi secondi: riconosce il cibo da testo, voce e foto (le foto con Llama 4 Scout). La chiave si crea su console.groq.com e resta nel portachiavi; testo e foto vanno ai server di Groq."
                         : ai.settings.engine == .deepseek
                         ? "DeepSeek costa pochi centesimi al mese a consumo (serve una piccola ricarica sul suo sito) e capisce solo testo e voce, non le foto."
                         : ai.settings.engine == .apple
                         ? "Il modello di Apple riconosce il cibo nella foto e stima i grammi, gratis e senza internet; i nutrienti vengono dalla tabella degli alimenti quando l'alimento c'è. È meno preciso di Claude: controlla sempre i grammi."
                         : ai.settings.engine == .gemini
                         ? "Gemini è gratuito entro i limiti giornalieri di Google, senza carta di credito. La chiave si crea con il tuo account Google su AI Studio e resta nel portachiavi dell'iPhone. Attenzione: con il livello gratuito Google può usare foto e richieste per migliorare i suoi prodotti."
                         : "Claude riconosce il cibo e stima grammi e nutrienti con più precisione. Si paga a consumo sul tuo account Anthropic, circa 2–6 centesimi a foto. La chiave resta nel portachiavi dell'iPhone e la foto va solo ad Anthropic.")
                }
                if FoodAI.isReady || hasKey {
                    Section {
                        Toggle("Analisi AI attiva", isOn: $ai.settings.enabled)
                        LabeledContent("Spesa del mese", value: "\(ai.monthCost.it(2)) $ su \(ai.settings.monthlyBudgetUSD.it(0)) $")
                        ProgressView(value: min(ai.monthCost / max(ai.settings.monthlyBudgetUSD, 0.01), 1))
                            .tint(ai.monthCost > ai.settings.monthlyBudgetUSD * 0.8 ? .orange : Theme.accent)
                        Stepper("Budget mensile: \(ai.settings.monthlyBudgetUSD.it(0)) $", value: $ai.settings.monthlyBudgetUSD,
                                in: 1...AIGuard.maxMonthlyBudgetCeiling, step: 1)
                        Stepper("Analisi al giorno: max \(ai.settings.dailyMaxCalls)", value: $ai.settings.dailyMaxCalls,
                                in: 1...AIGuard.maxDailyCallsCeiling)
                        LabeledContent("Analisi oggi", value: "\(ai.callsToday)")
                        if !ai.calls.isEmpty {
                            DisclosureGroup("Ultime analisi") {
                                ForEach(ai.calls.suffix(10).reversed()) { call in
                                    LabeledContent(call.date.formatted(date: .abbreviated, time: .shortened),
                                                   value: "\(call.outcome) · \(call.costUSD.it(3)) $")
                                        .font(.caption)
                                }
                            }
                        }
                    } header: { Text("Limiti e costi AI") } footer: {
                        Text("Oltre il budget del mese o il numero di analisi del giorno l'app blocca le richieste. Ogni analisi fa al massimo 3 tentativi. All'80% del budget ricevi una notifica. I costi sono stimati dai token che Anthropic riporta.")
                    }
                }
                Section {
                    if FoodStore.shared.isAvailable {
                        LabeledContent("Alimenti nel database", value: FoodStore.shared.count.formatted())
                        LabeledContent("Base del", value: FoodStore.shared.built ?? "–")
                        LabeledContent("Aggiornati via internet", value: dbUpdated.formatted())
                        LabeledContent("Ultimo aggiornamento", value: FoodUpdater.lastUpdate?.formatted(date: .abbreviated, time: .shortened) ?? "mai")
                        Button(dbUpdating ? "Aggiornamento in corso…" : "Aggiorna ora") {
                            dbUpdating = true
                            Task {
                                await FoodUpdater.run()
                                dbUpdated = FoodStore.shared.updatedCount
                                dbUpdating = false
                            }
                        }
                        .disabled(dbUpdating)
                    } else {
                        Text("Database grande non incluso in questa versione: uso la tabella di base e la ricerca online.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("Database alimenti") } footer: {
                    Text("Prodotti venduti in Italia da Open Food Facts (licenza ODbL, openfoodfacts.org) e alimenti generici da USDA FoodData Central. Si aggiorna da solo via internet ogni 7 giorni (in background, di solito di notte) con i prodotti nuovi o modificati.")
                }
                Section {
                    if let release = updates.available {
                        LabeledContent("Nuova versione", value: "\(release.version) (\(release.build))")
                        if !release.notes.isEmpty { Text(release.notes).font(.footnote).foregroundStyle(.secondary) }
                        Button("Aggiorna") { updates.openSideStore() }
                    } else {
                        LabeledContent("Versione", value: "\(UpdateChecker.currentVersion) (\(UpdateChecker.currentBuild)) · aggiornata")
                    }
                    if let last = updates.lastCheck {
                        LabeledContent("Ultimo controllo", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button(checking ? "Controllo…" : "Controlla aggiornamenti") {
                        checking = true
                        Task { await updates.checkIfNeeded(force: true); checking = false }
                    }
                    .disabled(checking)
                    Button("Aggiungi la fonte a SideStore") { updates.openSideStore() }
                } header: { Text("Aggiornamenti app") } footer: {
                    Text("Ogni nuova versione viene pubblicata automaticamente e l'app te lo segnala. Con SideStore si installa con un tocco; con Sideloadly \"Aggiorna\" apre la pagina dove scaricare l'.ipa da installare dal computer. I dati restano.")
                }
                Section("App") {
                    NavigationLink { GymSettingsView() } label: {
                        LabeledContent { Text(GymMonitor.shared.gym?.name ?? "Non impostata") } label: { Label("Palestra", systemImage: "mappin.and.ellipse") }
                    }
                    Toggle("Modalità semplice (pulsanti grandi)", isOn: $store.profile.simpleMode)
                    Toggle("Apple Salute", isOn: $store.profile.useHealth)
                        .onChange(of: store.profile.useHealth) { _, on in if on { Sync.importHealth(context: context) } }
                    if store.profile.useHealth {
                        HealthStatusRow { Sync.syncHealth(context: context) }
                    }
                    Button { app.sheet = .debug } label: { Label("Pannello di debug", systemImage: "ladybug") }
                }
                Section {
                    Text("Nomorediet \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · i dati restano su questo iPhone.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("I valori nutrizionali sono stime: non sostituiscono il parere di un medico o di un nutrizionista.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Profilo")
            .onAppear { manualText = store.profile.manualKcal.map { $0.it() } ?? "" }
            .onChange(of: scenePhase) { _, phase in if phase == .active { pickUpCopiedKey() } }
            .onChange(of: store.profile) { _, _ in Sync.afterFoodChange(context: context, day: DayId.today) }
        }
    }

    private func connectGemini(_ key: String) {
        geminiStatus = "Controllo…"
        Task {
            let result = await GeminiAI.connect(key: key)
            geminiStatus = result.message
            if result.ok { Keychain.save(key, service: Keychain.gemini); geminiReady = true; geminiKey = "" }
        }
    }

    private func connectCompatible(_ key: String, _ provider: OpenAICompatibleAI.Provider) {
        compatibleStatus[provider.name] = "Controllo…"
        Task {
            let result = await OpenAICompatibleAI.connect(key: key.trimmingCharacters(in: .whitespacesAndNewlines), provider: provider)
            compatibleStatus[provider.name] = result.message
            if result.ok { compatibleKey = "" }
        }
    }

    /// Back from AI Studio / the Anthropic console with a key copied: recognise it and connect it.
    private func pickUpCopiedKey() {
        guard let engine = waitingForKey, UIPasteboard.general.hasStrings,
              let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        switch engine {
        case .gemini where text.hasPrefix("AIza") && text.count >= 30:
            waitingForKey = nil
            connectGemini(text)
        case .claude where text.hasPrefix("sk-ant-"):
            waitingForKey = nil
            keyStatus = "Controllo…"
            Task {
                let result = await FoodAI.test(key: text)
                keyStatus = result
                if result.hasSuffix("✓") { Keychain.save(text); hasKey = true }
            }
        case .glm, .deepseek, .groq:
            if let provider = OpenAICompatibleAI.provider(engine), OpenAICompatibleAI.looksLikeKey(text, for: provider) {
                waitingForKey = nil
                connectCompatible(text, provider)
            }
        default: break
        }
    }
}

struct ProfileFields: View {
    @Binding var profile: Profile

    var body: some View {
        Section("Tu") {
            TextField("Nome", text: $profile.name)
            Picker("Sesso", selection: $profile.sex) {
                Text("Uomo").tag(Profile.Sex.uomo)
                Text("Donna").tag(Profile.Sex.donna)
            }
            Stepper("Età: \(profile.age) anni", value: $profile.age, in: 14...99)
            Stepper("Altezza: \(profile.heightCm.it()) cm", value: $profile.heightCm, in: 120...220)
            Stepper("Peso: \(profile.weightKg.it(1)) kg", value: $profile.weightKg, in: 35...250, step: 0.5)
            Stepper("Peso obiettivo: \(profile.targetKg.it(1)) kg", value: $profile.targetKg, in: 35...250, step: 0.5)
        }
        Section("Stile di vita") {
            Picker("Obiettivo", selection: $profile.goal) {
                ForEach(Profile.Goal.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if profile.goal == .dimagrire {
                let plan = Nutrition.plan(profile)
                NavigationLink { WeightPlanView() } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Piano per arrivare a \(profile.targetKg.it(1)) kg").font(.subheadline.weight(.semibold))
                        Text(plan.date.map { "\(plan.daily.it()) kcal al giorno · traguardo \($0.formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "it_IT"))))" }
                             ?? "\(plan.daily.it()) kcal al giorno")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Picker("Attività", selection: $profile.activity) {
                ForEach(Profile.Activity.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Stepper("Allenamenti: \(profile.trainingDays) a settimana", value: $profile.trainingDays, in: 0...7)
            Toggle("Vegetariano", isOn: $profile.vegetarian)
        }
    }
}

/// First launch: a few questions, then straight into the app.
struct OnboardingView: View {
    @EnvironmentObject private var store: ProfileStore
    @Environment(\.modelContext) private var context

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Benvenuto in Nomorediet").font(.title.bold())
                        Text("Rispondi a qualche domanda: calcolo calorie e macro per i giorni di allenamento e di riposo. Puoi cambiare tutto dopo in Profilo.")
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    HStack(spacing: 12) {
                        ForEach([Profile.Sex.uomo, .donna], id: \.self) { sex in
                            Button {
                                store.profile.sex = sex
                                PlanStore.shared.source = sex == .donna ? .nomorediet : PlanStore.shared.source
                            } label: {
                                VStack(spacing: 8) {
                                    MovementFigure(pattern: sex == .uomo ? "push_v" : "hip_thrust", size: 80, animated: store.profile.sex == sex)
                                    Text(sex == .uomo ? "Uomo" : "Donna").font(.headline)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(store.profile.sex == sex ? Theme.accent.opacity(0.2) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(store.profile.sex == sex ? Theme.accent : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .id(store.profile.sex)
                } header: { Text("Sei un uomo o una donna?") } footer: {
                    Text("Calorie, proteine, scheda di allenamento e animazioni si adattano. Puoi cambiarlo dopo in Profilo.")
                }
                ProfileFields(profile: $store.profile)
                Section {
                    Picker("Tipo di dieta", selection: $store.profile.diet) {
                        ForEach(Profile.Diet.allCases) { Text($0.title).tag($0) }
                    }
                    Text(store.profile.diet.summary).font(.footnote).foregroundStyle(.secondary)
                    WeekdayPicker(selection: $store.profile.trainingWeekdaySet)
                } header: { Text("Dieta e giorni di allenamento") } footer: {
                    Text("I giorni scelti sono giorni di allenamento per calorie, carboidrati e promemoria della creatina. Se ti alleni in un altro giorno, l'app lo capisce quando registri una serie.")
                }
                Section {
                    Button {
                        store.profile.onboarded = true
                        Sync.saveWeight(store.profile.weightKg, source: "profilo", context: context)
                        Reminders.configure(times: store.profile.reminderTimes, enabled: store.profile.reminders)
                        Sync.importHealth(context: context)
                    } label: {
                        Text("Inizia").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                }
            }
        }
    }
}

/// Seven toggles, Monday first.
struct WeekdayPicker: View {
    @Binding var selection: Set<Int>
    private let days = [(2, "L"), (3, "M"), (4, "M"), (5, "G"), (6, "V"), (7, "S"), (1, "D")]
    private static let names = ["domenica", "lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(days, id: \.0) { day, letter in
                let on = selection.contains(day)
                Button {
                    if on { selection.remove(day) } else { selection.insert(day) }
                } label: {
                    Text(letter).font(.subheadline.bold())
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(on ? Theme.accent : Color.secondary.opacity(0.15), in: Circle())
                        .foregroundStyle(on ? .white : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.names[day - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}


/// Whether Apple Health is really connected, with the reason when it is not.
private struct HealthStatusRow: View {
    @ObservedObject private var cache = HealthCache.shared
    var connect: () -> Void

    private var connected: Bool { cache.status?.hasPrefix("Collegata") == true }

    /// Separate rows: buttons and links sharing one Form row all fire together on a tap.
    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                Text(cache.status ?? "Non ancora letta")
                    .font(.footnote)
                    .foregroundStyle(connected ? Theme.accent : .orange)
                if let steps = cache.steps, connected {
                    Text("Oggi \(Int(steps).formatted()) passi").font(.footnote).foregroundStyle(.secondary)
                }
                if cache.status?.contains("entitlement") == true || cache.status?.contains("Comandi rapidi") == true {
                    Text("Per collegare Salute direttamente (passi e peso in automatico), installa Nomorediet con Impactor dal PC invece che con SideStore: mantiene il permesso di Salute anche con l'Apple ID gratuito. Poi qui premi \"Collega Apple Salute\" e scegli cosa condividere.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(connected ? "Sincronizza adesso" : "Collega Apple Salute") { connect() }
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier("health-connect")
            NavigationLink { HealthExportImportView() } label: {
                Text("Importa tutto da Salute (anche lo storico)").font(.footnote.weight(.semibold))
            }
            NavigationLink { HealthShortcutGuide() } label: {
                Text(connected ? "Collegamento con Comandi rapidi" : "Installata con SideStore? Collegala con Comandi rapidi")
                    .font(.footnote.weight(.semibold))
            }
        }
    }
}

/// How to bring Apple Health in through a Shortcuts automation (no HealthKit entitlement needed).
struct HealthShortcutGuide: View {
    private let fields: [(String, String)] = [
        ("Passi", "Tipo Passi, data Oggi"),
        ("Calorie attive / a riposo", "Energia attiva / Energia a riposo, data Oggi"),
        ("Distanza (km)", "Distanza camminata + corsa, data Oggi"),
        ("Minuti di esercizio", "Minuti di esercizio, data Oggi"),
        ("Piani saliti", "Piani saliti, data Oggi"),
        ("Peso / Grasso corporeo", "Peso / Percentuale di grasso corporeo, più recente prima, limite 1"),
        ("Battito medio", "Frequenza cardiaca, data Oggi (l'app fa la media)"),
        ("Battito a riposo", "Frequenza cardiaca a riposo, più recente prima, limite 1"),
        ("HRV (ms)", "Variabilità della frequenza cardiaca, data Oggi (l'app fa la media)"),
        ("VO2 max", "VO2 max, più recente prima, limite 1"),
        ("Ore di sonno", "Analisi del sonno, data Oggi → Ottieni dettagli: Durata (secondi, minuti o ore: l'app li converte)"),
    ]
    private let steps: [(String, String)] = [
        ("1", "Apri Comandi rapidi → Automazione → + → \"Ora del giorno\": scegli 22:00, Ogni giorno, e \"Esegui immediatamente\"."),
        ("2", "Aggiungi \"Trova campioni di Salute\": Tipo = Passi, Data di inizio = Oggi (non \"negli ultimi 7 giorni\")."),
        ("3", "Ripeti per Energia attiva ed Energia a riposo (data: oggi). Per il Peso: Tipo = Peso, ordina per data più recente, limite 1."),
        ("4", "Aggiungi l'azione di Nomorediet \"Invia dati Salute a Nomorediet\", tocca \"Mostra altro\", poi ogni campo (Passi, Calorie attive…) → Seleziona variabile → il suo \"Campioni di Salute\". Non serve \"Calcola statistiche\": l'app somma da sola."),
        ("5", "Chiama il comando \"Nomorediet Salute\" (va bene anche \"Invia dati Salute a Nomorediet\"): così i tasti Sincronizza dell'app lo avviano da soli. Tocca ▶︎ per provarlo: compare \"Ricevuto: … passi\"."),
        ("+", "Consiglio: crea una seconda automazione \"App → Nomorediet → Viene aperta\" con lo stesso comando, così i dati sono aggiornati ogni volta che apri l'app."),
    ]

    var body: some View {
        List {
            Section {
                Text("Le app installate con SideStore e un Apple ID gratuito non ricevono da Apple il permesso di leggere Salute. Comandi rapidi invece può leggerla: un'automazione passa a Nomorediet passi, calorie e peso di ogni giorno. I dati restano sull'iPhone.")
                    .font(.subheadline)
            }
            Section("Come si fa (5 minuti, una volta sola)") {
                ForEach(steps, id: \.0) { number, text in
                    HStack(alignment: .top, spacing: 12) {
                        Text(number).font(.headline).foregroundStyle(Theme.accent).frame(width: 22)
                        Text(text).font(.subheadline)
                    }
                }
            }
            Section {
                ForEach(fields, id: \.0) { field, how in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(field).font(.subheadline.weight(.semibold))
                        Text(how).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Tutti i campi: cosa cercare con Trova campioni di Salute") }
            Section {
                Button("Apri Comandi rapidi") {
                    if let url = URL(string: "shortcuts://") { UIApplication.shared.open(url) }
                }
            } footer: {
                Text("Le calorie a riposo arrivano dall'Apple Watch: con 7 giorni di passi e calorie l'obiettivo calorico usa il tuo consumo reale.")
            }
        }
        .navigationTitle("Salute con Comandi rapidi")
        .navigationBarTitleDisplayMode(.inline)
    }
}
