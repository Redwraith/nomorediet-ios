import Foundation
import UIKit

/// The main food recognition algorithm, used for photos (plates and packs), typed and spoken meals.
///
/// Based on DietAI24 (Nature Communications Medicine, 2025) and open-source loggers such as NutriTrack and
/// fitness-log: the model is good at recognising food and bad at nutrition numbers, so
///  1. RECOGNISE — the AI lists each food with a short description, cooking state, portion and grams;
///  2. RETRIEVE — it picks the matching entry from Nomorediet's food table (the catalog is in the prompt for
///     cloud engines; multi-query fuzzy search on the device for Apple and the offline parser);
///  3. PORTION — for a catalog food it counts standard portions ("2 uova", "1 piatto") instead of guessing grams;
///  4. COMPUTE — nutrients = table values × grams, deterministically. The model's own numbers are used only for
///     foods missing from the table, and those rows are marked "stima AI";
///  5. LEARN — the user's gram corrections are passed back as context next time.
enum MealRecognizer {
    struct Input {
        var image: UIImage?
        var text: String = ""
        var volumeMl: Double? = nil
        /// Text printed on a pack in the photo (product name, type).
        var packaging: [String] = []
        /// Grams read on a kitchen scale in the photo.
        var scaleGrams: Double? = nil
        /// What Apple's image classifier sees, as a hint for the model.
        var hint = ""
        /// The user confirmed the photo shows food: skip the on-device gate.
        var force = false
    }

    /// One food as the model returns it, before grounding.
    struct Raw {
        var name: String
        var description = ""
        var catalogMatch = ""
        /// English name, to search the USDA part of the large database.
        var nameEn = ""
        var portionCount = 0.0
        var grams: Double
        var per100: Nutrients
        var confidence = "media"
    }

    // MARK: Entry point

    /// Runs the selected engine, then grounds the result in the food table. Without a ready engine, typed or
    /// spoken meals still work with the offline parser.
    @MainActor static func recognize(_ input: Input, foods: [Food]) async throws -> FoodAI.Result {
        let corrections = FoodAI.Corrections.all
        var input = input
        // 0. GATE — no food in the photo (a computer, a desk): stop before any AI can invent a meal
        var guesses: [DishClassifier.Guess] = []
        if let image = input.image { guesses = await DishClassifier.classify(image) }
        let sureDish = (guesses.first?.confidence ?? 0) >= 0.5
        if let image = input.image, !input.force, !sureDish, input.text.isEmpty {
            switch await FoodGate.check(image) {
            case .notFood(let what): throw FoodAI.Failure.notFood(what)
            case .food: input.hint = "Il classificatore dell'iPhone conferma che nella foto c'è cibo."
            case .unsure: input.hint = "Il classificatore dell'iPhone non è sicuro che nella foto ci sia cibo: controlla bene."
            }
        }
        if !guesses.isEmpty { input.hint += (input.hint.isEmpty ? "" : " ") + DishClassifier.hint(guesses) }
        let raw: (dish: String, items: [Raw], note: String)
        aiScaleGrams = 0
        if FoodAI.isReady {
            do {
                switch AIGuard.shared.settings.engine {
                case .apple: raw = try await OnDeviceAI.recognize(input, corrections: corrections)
                case .claude: raw = try await FoodAI.recognize(input, catalog: catalog(foods), corrections: corrections)
                case .gemini: raw = try await GeminiAI.recognize(input, catalog: catalog(foods), corrections: corrections)
                case .glm, .deepseek:
                    guard let provider = OpenAICompatibleAI.provider(AIGuard.shared.settings.engine) else { throw FoodAI.Failure.empty }
                    raw = try await OpenAICompatibleAI.recognize(input, catalog: catalog(foods), corrections: corrections, provider: provider)
                }
            } catch {
                // a typed or spoken meal never ends with nothing: when the AI fails, the offline parser takes over
                guard input.image == nil, !input.text.isEmpty else { throw error }
                let parsed = TextMealParser.parse(input.text)
                guard !parsed.isEmpty else { throw error }
                DebugLog.shared.add("error", "ai", "AI non riuscita, uso l'analisi semplice: \(error.localizedDescription)")
                raw = ("Pasto", parsed, "L'AI non ha risposto: analisi semplice, controlla alimenti e grammi.")
            }
        } else if input.image != nil, input.text.isEmpty, let dish = guesses.first(where: { $0.confidence >= 0.3 }) {
            // offline: the on-device recogniser's best dish, at its standard portion
            raw = (dish.dish, [Raw(name: dish.dish, nameEn: dish.dish, grams: 0, per100: Nutrients(), confidence: "bassa")],
                   "Riconosciuto sul telefono senza AI: controlla piatto e grammi.")
        } else if input.image == nil, !input.text.isEmpty {
            raw = ("Pasto", TextMealParser.parse(input.text), "Analisi senza AI: controlla alimenti e grammi.")
        } else {
            throw FoodAI.Failure.server("scegli e attiva un motore in Profilo → Analisi AI.")
        }
        // grounding searches the large database: keep it off the main thread
        let rawItems = raw.items
        var items = await Task.detached(priority: .userInitiated) { rawItems.compactMap { ground($0, in: foods) } }.value
        guard !items.isEmpty else { throw FoodAI.Failure.empty }
        // a kitchen scale in the photo beats any estimate: its weight is the food on it
        var note = raw.note
        // the model decides whether a number in the photo is a scale display (not the net weight printed on a pack)
        if aiScaleGrams >= 1, aiScaleGrams <= 5000, input.image != nil {
            let scale = aiScaleGrams.rounded()
            items = applyScale(scale, to: items)
            note = "⚖️ Peso letto sulla bilancia: \(scale.it()) g." + (note.isEmpty ? "" : " " + note)
        }
        return FoodAI.Result(dish: raw.dish, items: items, note: note)
    }

    /// Grams read by the model on a scale display in the photo (0 = none).
    @MainActor static var aiScaleGrams = 0.0

    /// One food: it weighs what the scale says. Several: the scale total is split in the proportions the AI estimated.
    static func applyScale(_ grams: Double, to items: [FoodAI.Item]) -> [FoodAI.Item] {
        let estimated = items.reduce(0) { $0 + $1.grams }
        guard estimated > 0 else { return items }
        return items.map { item in
            var item = item
            item.grams = items.count == 1 ? grams : (grams * item.grams / estimated).rounded()
            return item
        }
    }

    // MARK: Prompt

    static let system = """
    Sei il nutrizionista di Nomorediet, un'app italiana per contare calorie e nutrienti. Ricevi la foto di un pasto \
    e/o la sua descrizione scritta o dettata a voce.

    Procedi così:
    1. Riconosci ogni alimento separatamente (anche condimenti evidenti o tipici: olio, sughi, formaggio grattugiato). \
    Per i piatti composti elenca gli ingredienti principali come voci separate quando si distinguono.
    2. Per ogni alimento scrivi una breve descrizione (varietà, ingredienti, cottura: crudo/cotto/fritto/al forno) e il \
    nome generico in inglese in name_en (per esempio "pasta, cooked", "chickpeas, canned").
    3. Se nel CATALOGO c'è lo stesso alimento nello stesso stato (cotto con cotto, crudo con crudo), copia in \
    catalog_match il nome del catalogo esattamente com'è scritto; altrimenti lascia catalog_match vuoto. Non scegliere \
    un alimento solo simile: meglio vuoto che sbagliato.
    4. Quantità: se l'alimento è nel catalogo ed è contabile nella sua porzione standard (uova, fette, vasetti, piatti), \
    metti in portion_count quante porzioni vedi o sono state dette; altrimenti 0. In ogni caso stima i grammi \
    effettivi in grams, o usa le quantità dette dall'utente. Per stimare i grammi da una foto ragiona sulla geometria, non \
    a occhio: (a) trova un oggetto di misura nota (piatto piano ≈ 26 cm di diametro, piatto fondo ≈ 22 cm, piattino ≈ 19 cm, \
    forchetta ≈ 19 cm, cucchiaio ≈ 17 cm, coltello ≈ 22 cm, lattina 33 cl ≈ 12 cm di altezza, bicchiere ≈ 9 cm, carta di \
    credito 8,5 cm, palmo di una mano adulta ≈ 8–9 cm di larghezza); (b) da quello ricava la superficie in cm² che ogni \
    alimento occupa e il suo spessore in cm, considerando la prospettiva; (c) volume = superficie × spessore (meno per forme \
    a cupola); (d) grammi = volume × densità tipica (pasta e riso cotti ≈ 0,6–0,8 g/ml, verdure a foglia ≈ 0,2–0,3, \
    verdure cotte ≈ 0,7, carne e pesce ≈ 1,0, legumi cotti ≈ 0,8, purè e zuppe ≈ 1,0, pane ≈ 0,25–0,4, formaggi ≈ 1,1). \
    Nel note indica brevemente quale riferimento hai usato.
    5. I valori per 100 g (kcal, proteine, carboidrati, grassi, fibre in g; ferro, calcio, zinco in mg; B12 in µg) \
    servono solo per gli alimenti senza catalog_match: usa le tabelle CREA/USDA per l'alimento così come è nel piatto.
    6. confidence: "alta", "media" o "bassa". In note una frase su cosa può rendere imprecisa la stima, o vuoto.
    Se l'utente dice quantità precise ("200 g", "2 uova"), usale.
    PRIMA DI TUTTO decidi contains_food: true solo se nella foto o nel testo ci sono davvero cibo o bevande. Oggetti \
    (computer, tastiere, telefoni, schermi, mobili, libri, vestiti), persone, animali, stanze o confezioni vuote NON sono \
    cibo, anche se colori o forme ricordano un alimento: in quel caso contains_food false, items vuoto e in note scrivi \
    cosa vedi (per esempio "un computer portatile"). Non inventare mai alimenti che non vedi o che l'utente non ha detto.
    Nomi in italiano, semplici e generici.
    """

    /// The food table as the model sees it: "Name | standard portion = grams".
    static func catalog(_ foods: [Food]) -> String {
        var seen = Set<String>()
        return foods.filter { seen.insert($0.name).inserted }
            .map { "\($0.name) | \($0.portionName) = \(Int($0.portion)) g" }
            .joined(separator: "\n")
    }

    static func userText(_ input: Input, corrections: [String]) -> String {
        var text = input.image == nil ? "Ecco cosa ha mangiato l'utente." : "Analizza questo pasto."
        if !input.text.isEmpty { text += " L'utente dice: \"\(input.text.prefix(600))\"." }
        if !input.hint.isEmpty { text += " " + input.hint }
        if let grams = input.scaleGrams {
            text += " Nel testo della foto si legge \"\(Int(grams)) g\": se è il display di una bilancia da cucina (e non il peso stampato su una confezione), è il peso del cibo appoggiato sopra."
        }
        if !input.packaging.isEmpty {
            text += " Sulla confezione nella foto si legge: \"\(input.packaging.joined(separator: " / ").prefix(200))\". " +
                "Usa questo testo per il nome esatto del prodotto e il tipo (per esempio \"yogurt greco 0%\", \"biscotti integrali\")."
        }
        if let ml = input.volumeMl { text += " Il LiDAR dell'iPhone ha misurato circa \(Int(ml)) ml di cibo sopra il piatto: usalo per i grammi." }
        if !corrections.isEmpty { text += " Correzioni passate dell'utente (tienine conto): " + corrections.suffix(8).joined(separator: "; ") + "." }
        return text
    }

    static let itemFields = ["name", "name_en", "description", "catalog_match", "portion_count", "grams", "kcal_100g", "protein_100g",
                             "carbs_100g", "fat_100g", "fiber_100g", "iron_mg_100g", "calcium_mg_100g", "zinc_mg_100g",
                             "b12_ug_100g", "confidence"]

    /// JSON schema for Claude (lowercase types, closed objects) or Gemini (OpenAPI subset).
    static func schema(gemini: Bool) -> [String: Any] {
        func t(_ name: String) -> String { gemini ? name.uppercased() : name }
        var item: [String: Any] = ["type": t("object"), "required": itemFields]
        var props: [String: Any] = [:]
        for field in itemFields {
            switch field {
            case "name", "name_en", "description", "catalog_match": props[field] = ["type": t("string")]
            case "confidence": props[field] = ["type": t("string"), "enum": ["alta", "media", "bassa"]]
            default: props[field] = ["type": t("number")]
            }
        }
        item["properties"] = props
        var root: [String: Any] = [
            "type": t("object"),
            "properties": ["contains_food": ["type": t("boolean")], "scale_grams": ["type": t("number")], "dish": ["type": t("string")],
                           "note": ["type": t("string")], "items": ["type": t("array"), "items": item]],
            "required": ["contains_food", "scale_grams", "dish", "items", "note"],
        ]
        if !gemini {
            item["additionalProperties"] = false
            root["properties"] = ["contains_food": ["type": "boolean"], "scale_grams": ["type": "number"], "dish": ["type": "string"],
                                  "note": ["type": "string"], "items": ["type": "array", "items": item]]
            root["additionalProperties"] = false
        }
        return root
    }

    /// Reads the JSON returned by the cloud engines.
    static func parse(_ json: [String: Any]) -> (dish: String, items: [Raw], note: String) {
        let items = (json["items"] as? [[String: Any]] ?? []).compactMap { row -> Raw? in
            let n = { (k: String) in (row[k] as? NSNumber)?.doubleValue ?? 0 }
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            return Raw(name: name, description: row["description"] as? String ?? "",
                       catalogMatch: row["catalog_match"] as? String ?? "", nameEn: row["name_en"] as? String ?? "", portionCount: n("portion_count"), grams: n("grams"),
                       per100: Nutrients(kcal: n("kcal_100g"), protein: n("protein_100g"), carbs: n("carbs_100g"),
                                         fat: n("fat_100g"), fiber: n("fiber_100g"), iron: n("iron_mg_100g"),
                                         calcium: n("calcium_mg_100g"), b12: n("b12_ug_100g"), zinc: n("zinc_mg_100g")),
                       confidence: row["confidence"] as? String ?? "media")
        }
        return (json["dish"] as? String ?? "Pasto", items, json["note"] as? String ?? "")
    }

    // MARK: Grounding

    /// Ties one recognised food to the table: exact catalog name first, then a careful fuzzy match.
    /// Returns nil for rows without a usable quantity.
    static func ground(_ raw: Raw, in foods: [Food]) -> FoodAI.Item? {
        let food = foods.first { FoodDatabase.normalize($0.name) == FoodDatabase.normalize(raw.catalogMatch) && !raw.catalogMatch.isEmpty }
            ?? bestMatch(for: [raw.name, raw.description], in: foods)
            ?? fromLargeDatabase(raw)
        var grams = raw.grams
        if let food, raw.portionCount > 0 { grams = raw.portionCount * food.portion }
        if grams <= 0, let food { grams = food.portion }
        guard grams > 0 else { return nil }
        grams = min(max(grams, 1), 2500).rounded()
        if let food {
            return FoodAI.Item(name: food.name, grams: grams, per100: food.per100, confidence: raw.confidence, fromTable: true,
                               detail: raw.name == food.name ? raw.description : raw.name)
        }
        guard raw.per100.kcal > 0 || raw.per100.protein + raw.per100.carbs + raw.per100.fat > 0 else { return nil }
        return FoodAI.Item(name: raw.name, grams: grams, per100: raw.per100, confidence: raw.confidence, fromTable: false, detail: raw.description)
    }

    /// Retrieval from the large weekly database (Open Food Facts Italy + USDA): candidates for the Italian and
    /// English names, then the same careful matching as for the catalog.
    static func fromLargeDatabase(_ raw: Raw) -> Food? {
        let store = FoodStore.shared
        guard store.isAvailable else { return nil }
        var candidates: [Food] = []
        for query in [raw.name, raw.nameEn] where !query.isEmpty {
            candidates += store.search(query, limit: 30)
        }
        return bestMatch(for: [raw.name, raw.nameEn, raw.description], in: candidates)
    }

    /// Multi-query fuzzy match (DietAI24 retrieval, without embeddings): every query is searched and the
    /// candidate covering most of the query words wins. Raw ingredients are only matched when the text says raw.
    static func bestMatch(for queries: [String], in foods: [Food]) -> Food? {
        let text = FoodDatabase.normalize(queries.joined(separator: " "))
        let wantsRaw = text.contains("crud")
        let stop: Set<String> = ["di", "al", "alla", "allo", "con", "e", "in", "il", "la", "lo", "le", "i", "gli", "un", "una", "del", "della", "a"]
        // how it is cooked or served does not make a food a different one: "riso" is "riso basmati cotto", not "gallette di riso"
        let state: Set<String> = ["cotto", "cotta", "cotti", "cotte", "bollito", "bollita", "lessato", "lessata", "intero", "intera",
                                  "fresco", "fresca", "naturale", "bianco", "bianca"]
        var best: (Food, Double)?
        for query in queries where !query.isEmpty {
            let words = FoodDatabase.normalize(query).split(whereSeparator: { !$0.isLetter }).map(String.init)
                .filter { $0.count > 2 && !stop.contains($0) }
            guard !words.isEmpty else { continue }
            for food in foods {
                let name = FoodDatabase.normalize(food.name)
                if name.contains("crud") && !wantsRaw { continue }
                let allNameWords = name.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count > 2 && !stop.contains($0) }
                guard let firstName = allNameWords.first else { continue }
                let nameWords = allNameWords.filter { !state.contains($0) || words.contains($0) }
                guard !nameWords.isEmpty else { continue }
                let covered = Double(words.filter { w in allNameWords.contains { same($0, w) } }.count) / Double(words.count)
                let precision = Double(nameWords.filter { n in words.contains { same($0, n) } }.count) / Double(nameWords.count)
                // the food the name starts with ("riso …") beats one that only contains it ("gallette di riso")
                let head = same(firstName, words[0]) ? 0.15 : 0
                let score = covered * 0.6 + precision * 0.4 + head
                if score >= 0.6, score > (best?.1 ?? 0) { best = (food, score) }
            }
        }
        return best?.0
    }

    /// Same word ignoring Italian singular/plural endings: "uova" ≈ "uovo", "pomodori" ≈ "pomodoro".
    static func same(_ a: String, _ b: String) -> Bool {
        func stem(_ w: String) -> String { String(w.prefix(max(3, min(6, w.count - 1)))) }
        return a.hasPrefix(stem(b)) || b.hasPrefix(stem(a))
    }
}

/// Offline parser for typed or spoken meals when no AI engine is ready:
/// "200 g di riso, 2 uova e un'insalata con olio".
enum TextMealParser {
    private static let numberWords: [String: Double] = ["un": 1, "uno": 1, "una": 1, "mezzo": 0.5, "mezza": 0.5, "due": 2, "tre": 3,
                                                        "quattro": 4, "cinque": 5, "sei": 6, "sette": 7, "otto": 8, "dieci": 10]

    static func parse(_ text: String) -> [MealRecognizer.Raw] {
        var normalized = FoodDatabase.normalize(text)
        for filler in ["ho mangiato", "ho bevuto", "mangiato", "bevuto", "a colazione", "a pranzo", "a cena", "per colazione",
                       "per pranzo", "per cena", "come spuntino", "oggi", "stamattina", "stasera", "circa", "tipo", "poi"] {
            // whole words only: "oggi" must not break "formaggio"
            normalized = normalized.replacingOccurrences(of: "\\b\(filler)\\b", with: " ", options: .regularExpression)
        }
        let separators = try! NSRegularExpression(pattern: ",|;|\\n|\\be\\b|\\bpoi\\b|\\bcon\\b|\\bpiu\\b")
        let ns = normalized as NSString
        let marked = separators.stringByReplacingMatches(in: normalized, range: NSRange(location: 0, length: ns.length), withTemplate: "|")
        return marked.split(separator: "|").compactMap { chunk -> MealRecognizer.Raw? in
            var part = chunk.trimmingCharacters(in: .whitespaces)
            guard part.count > 1 else { return nil }
            var grams = 0.0, count = 0.0
            let gramsRegex = try! NSRegularExpression(pattern: "(\\d+(?:[.,]\\d+)?)\\s*(g|gr|grammi|grammo|ml|kg)\\b(\\s*di)?")
            let pns = part as NSString
            if let m = gramsRegex.firstMatch(in: part, range: NSRange(location: 0, length: pns.length)) {
                let value = pns.substring(with: m.range(at: 1)).italianDouble ?? 0
                grams = pns.substring(with: m.range(at: 2)) == "kg" ? value * 1000 : value
                part = pns.replacingCharacters(in: m.range, with: " ")
            } else if let first = part.split(separator: " ").first {
                let word = String(first)
                if let n = word.italianDouble { count = n; part = String(part.dropFirst(word.count)) }
                else if let n = numberWords[word] { count = n; part = String(part.dropFirst(word.count)) }
            }
            let name = part.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return MealRecognizer.Raw(name: name, portionCount: count, grams: grams, per100: .zero, confidence: "media")
        }
    }
}
