import XCTest
@testable import Nomorediet

final class NutritionTests: XCTestCase {
    func testTrainingAndRestDaysKeepTheWeeklyAverage() {
        var p = Profile()
        p.trainingDays = 4
        p.manualKcal = 2400
        let train = Nutrition.goals(p, kind: .training).kcal
        let rest = Nutrition.goals(p, kind: .rest).kcal
        XCTAssertGreaterThan(train, rest)
        XCTAssertEqual((train * 4 + rest * 3) / 7, 2400, accuracy: 2)
    }

    func testMacrosAreSensible() {
        let g = Nutrition.goals(Profile(), kind: .rest)
        XCTAssertGreaterThan(g.protein, 100)
        XCTAssertGreaterThanOrEqual(g.carbs, 50)
        XCTAssertEqual(g.protein * 4 + g.carbs * 4 + g.fat * 9, g.kcal, accuracy: g.kcal * 0.05)
    }

    func testVegetarianNeedsMoreIronAndZinc() {
        var veg = Profile(); veg.vegetarian = true
        var omni = Profile(); omni.vegetarian = false
        XCTAssertGreaterThan(Nutrition.goals(veg, kind: .rest).iron, Nutrition.goals(omni, kind: .rest).iron)
        XCTAssertGreaterThan(Nutrition.goals(veg, kind: .rest).zinc, Nutrition.goals(omni, kind: .rest).zinc)
    }

    func testAdaptiveMaintenanceFromIntakeAndWeightTrend() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // 0,5 kg lost per week while eating 2500 kcal → maintenance ≈ 2500 + 0,5 × 7700 / 7 ≈ 3050
        let weights = (0..<15).map { (start.addingTimeInterval(Double($0) * 86400), 90 - Double($0) * 0.5 / 7) }
        let tdee = Nutrition.adaptiveTDEE(intakes: Array(repeating: 2500, count: 14), weights: weights)
        XCTAssertNotNil(tdee)
        XCTAssertEqual(tdee ?? 0, 3050, accuracy: 15)
    }

    func testAdaptiveMaintenanceNeedsEnoughData() {
        let weights = [(Date(), 80.0), (Date().addingTimeInterval(86400), 80.0)]
        XCTAssertNil(Nutrition.adaptiveTDEE(intakes: [2000, 2000], weights: weights))
    }

    func testNutrientsScaleWithGrams() {
        let per100 = Nutrients(kcal: 350, protein: 12, carbs: 70, fat: 2)
        XCTAssertEqual(per100.scaled(0.8).kcal, 280, accuracy: 0.001)
        XCTAssertEqual((per100 + per100).protein, 24)
    }
}

final class ParsingTests: XCTestCase {
    func testSpokenWeights() {
        XCTAssertEqual(SpokenNumber.kilograms("85,4") ?? 0, 85.4, accuracy: 0.001)
        XCTAssertEqual(SpokenNumber.kilograms("ottantacinque e quattro") ?? 0, 85.4, accuracy: 0.001)
        XCTAssertEqual(SpokenNumber.kilograms("ottantuno") ?? 0, 81, accuracy: 0.001)
        XCTAssertEqual(SpokenNumber.kilograms("settantotto e mezzo") ?? 0, 78.5, accuracy: 0.001)
        XCTAssertEqual(SpokenNumber.kilograms("centodue chili") ?? 0, 102, accuracy: 0.001)
        XCTAssertNil(SpokenNumber.kilograms("buongiorno"))
    }

    func testNutritionLabel() {
        let lines = ["Valori nutrizionali per 100 g", "Energia 1550 kJ / 370 kcal", "Grassi 2,0 g",
                     "di cui acidi grassi saturi 0,4 g", "Carboidrati 72 g", "Fibre 3 g", "Proteine 12 g", "Sale 0,01 g"]
        let n = TextReader.label(lines)
        XCTAssertEqual(n.kcal, 370)
        XCTAssertEqual(n.fat, 2)
        XCTAssertEqual(n.carbs, 72)
        XCTAssertEqual(n.protein, 12)
        XCTAssertEqual(n.fiber, 3)
    }

    func testScaleDisplay() {
        XCTAssertEqual(TextReader.scaleWeight(["12:30", "85,4", "kg"]) ?? 0, 85.4, accuracy: 0.001)
        XCTAssertNil(TextReader.scaleWeight(["12:30", "BMI 24"]))
        XCTAssertEqual(TextReader.scaleWeight(["Grasso 31,5%", "78,2 kg"]) ?? 0, 78.2, accuracy: 0.001)
    }

    func testFoodSearchIgnoresAccentsAndCase() {
        XCTAssertTrue(FoodDatabase.search("yogurt greco").first?.name.hasPrefix("Yogurt greco") ?? false)
        XCTAssertFalse(FoodDatabase.search("CAFFE").isEmpty)
        XCTAssertTrue(FoodDatabase.search("zzzz").isEmpty)
    }

    func testFoodDatabaseValuesAreConsistent() {
        // alcohol (7 kcal/g) is not among the macros
        for food in FoodDatabase.foods where !["Birra", "Vino rosso"].contains(food.name) {
            let n = food.per100
            let fromMacros = n.protein * 4 + n.carbs * 4 + n.fat * 9
            XCTAssertLessThanOrEqual(n.protein + n.carbs + n.fat, 101, food.name)
            // energy from macros within 25% (fibre and alcohol explain the rest)
            if n.kcal > 50 { XCTAssertEqual(fromMacros, n.kcal, accuracy: n.kcal * 0.25 + 15, food.name) }
        }
    }
}

@MainActor
final class AIGuardTests: XCTestCase {
    func testBackoffGrowsAndIsCapped() {
        XCTAssertEqual(AIGuard.backoff(attempt: 1, retryAfter: nil), 2)
        XCTAssertEqual(AIGuard.backoff(attempt: 2, retryAfter: nil), 4)
        XCTAssertEqual(AIGuard.backoff(attempt: 9, retryAfter: nil), 20)
        XCTAssertEqual(AIGuard.backoff(attempt: 1, retryAfter: "30"), 20)
        XCTAssertEqual(AIGuard.backoff(attempt: 1, retryAfter: "3"), 3)
    }

    func testKillSwitchBlocksRequests() {
        let guardian = AIGuard.shared
        let saved = guardian.settings
        defer { guardian.settings = saved }
        guardian.settings.enabled = false
        XCTAssertThrowsError(try guardian.begin())
    }

    func testOnlyOneRequestAtATime() throws {
        let guardian = AIGuard.shared
        let saved = guardian.settings
        defer { guardian.settings = saved; guardian.end() }
        guardian.settings = AIGuard.Settings(enabled: true, monthlyBudgetUSD: AIGuard.maxMonthlyBudgetCeiling, dailyMaxCalls: AIGuard.maxDailyCallsCeiling)
        try guardian.begin()
        XCTAssertThrowsError(try guardian.begin())
    }
}

final class GeminiModelTests: XCTestCase {
    func testPicksNewestStableFlashModelThatReadsImages() {
        let models: [[String: Any]] = [
            ["name": "models/gemini-2.5-flash", "supportedGenerationMethods": ["generateContent"]],
            ["name": "models/gemini-3-flash-preview", "supportedGenerationMethods": ["generateContent"]],
            ["name": "models/gemini-3-flash", "supportedGenerationMethods": ["generateContent"]],
            ["name": "models/gemini-3.1-flash-lite", "supportedGenerationMethods": ["generateContent"]],
            ["name": "models/gemini-3-flash-image", "supportedGenerationMethods": ["generateContent"]],
            ["name": "models/gemini-3-pro", "supportedGenerationMethods": ["generateContent"]],
            ["name": "models/text-embedding-004", "supportedGenerationMethods": ["embedContent"]],
        ]
        XCTAssertEqual(GeminiAI.pickModel(models), "models/gemini-3-flash")
        XCTAssertNil(GeminiAI.pickModel([["name": "models/gemini-3-pro", "supportedGenerationMethods": ["generateContent"]]]))
    }
}

final class MealRecognizerTests: XCTestCase {
    private let foods = FoodDatabase.foods

    func testCatalogMatchUsesTableValuesAndStandardPortions() {
        let raw = MealRecognizer.Raw(name: "Uova sode", catalogMatch: "Uovo intero", portionCount: 2, grams: 100, per100: .zero)
        let item = MealRecognizer.ground(raw, in: foods)
        XCTAssertEqual(item?.name, "Uovo intero")
        XCTAssertEqual(item?.grams, 120)
        XCTAssertEqual(item?.fromTable, true)
        XCTAssertEqual(item?.per100.kcal, 143)
    }

    func testUnknownFoodKeepsTheModelEstimate() {
        let raw = MealRecognizer.Raw(name: "Tajine marocchina di verdure", grams: 300,
                                     per100: Nutrients(kcal: 90, protein: 3, carbs: 12, fat: 3))
        let item = MealRecognizer.ground(raw, in: foods)
        XCTAssertEqual(item?.fromTable, false)
        XCTAssertEqual(item?.grams, 300)
    }

    func testFuzzyMatchPrefersCookedFoods() {
        XCTAssertEqual(MealRecognizer.bestMatch(for: ["pasta"], in: foods)?.name, "Pasta cotta")
        XCTAssertEqual(MealRecognizer.bestMatch(for: ["pasta cruda"], in: foods)?.name.contains("crud"), true)
        XCTAssertEqual(MealRecognizer.bestMatch(for: ["riso basmati"], in: foods)?.name, "Riso basmati cotto")
        XCTAssertEqual(MealRecognizer.bestMatch(for: ["2 uova"], in: foods)?.name, "Uovo intero")
        XCTAssertNil(MealRecognizer.bestMatch(for: ["cous cous di cavolfiore al curry"], in: [foods.first { $0.name == "Mela" }!]))
    }

    func testOfflineParserReadsQuantities() {
        let raws = TextMealParser.parse("Ho mangiato 200 g di riso basmati, 2 uova e un'insalata")
        let items = raws.compactMap { MealRecognizer.ground($0, in: foods) }
        XCTAssertEqual(items.map(\.name), ["Riso basmati cotto", "Uovo intero", "Insalata verde"])
        XCTAssertEqual(items.map(\.grams), [200, 120, 80])
    }

    func testSchemasListEveryField() {
        for gemini in [false, true] {
            let items = (MealRecognizer.schema(gemini: gemini)["properties"] as? [String: Any])?["items"] as? [String: Any]
            let item = items?["items"] as? [String: Any]
            XCTAssertEqual(Set((item?["properties"] as? [String: Any])?.keys.map { $0 } ?? []), Set(MealRecognizer.itemFields))
        }
    }

    func testParsesCloudJSON() {
        let json: [String: Any] = ["dish": "Pranzo", "note": "", "items": [
            ["name": "Pasta al pesto", "description": "pasta cotta con pesto", "catalog_match": "Pasta cotta", "portion_count": 1,
             "grams": 220, "kcal_100g": 200, "protein_100g": 6, "carbs_100g": 30, "fat_100g": 6, "fiber_100g": 2,
             "iron_mg_100g": 1, "calcium_mg_100g": 20, "zinc_mg_100g": 1, "b12_ug_100g": 0, "confidence": "alta"]]]
        let parsed = MealRecognizer.parse(json)
        XCTAssertEqual(parsed.items.count, 1)
        let item = MealRecognizer.ground(parsed.items[0], in: foods)
        XCTAssertEqual(item?.name, "Pasta cotta")
        XCTAssertEqual(item?.grams, 200) // 1 standard portion of the table, not the model's 220 g
        XCTAssertEqual(item?.detail, "Pasta al pesto")
    }
}

final class TextMealParserTests: XCTestCase {
    func testFillerWordsDoNotBreakFoodNames() {
        let raws = TextMealParser.parse("oggi formaggio grana")
        XCTAssertEqual(raws.first?.name, "formaggio grana")
    }
}

final class FoodStoreTests: XCTestCase {
    func testLargeDatabaseSearchAndBarcode() throws {
        let store = FoodStore.shared
        try XCTSkipUnless(store.isAvailable, "large database not bundled in this build")
        XCTAssertGreaterThan(store.count, 1000)
        let pasta = store.search("pasta")
        XCTAssertFalse(pasta.isEmpty)
        XCTAssertTrue(pasta.allSatisfy { $0.per100.kcal >= 0 && $0.per100.kcal <= 950 })
        if let withCode = pasta.first(where: { $0.barcode != nil }), let code = withCode.barcode {
            XCTAssertEqual(store.product(barcode: code)?.barcode, code)
        }
    }

    func testRecognizerFallsBackToLargeDatabase() throws {
        try XCTSkipUnless(FoodStore.shared.isAvailable, "large database not bundled in this build")
        let raw = MealRecognizer.Raw(name: "Hummus di ceci", nameEn: "hummus", grams: 60, per100: .zero)
        XCTAssertNotNil(MealRecognizer.fromLargeDatabase(raw))
    }
}

final class FoodUpdatesTests: XCTestCase {
    func testUpdatedProductsReplaceBundledOnes() throws {
        try XCTSkipUnless(FoodStore.shared.isAvailable, "large database not bundled in this build")
        let code = "999000\(Int.random(in: 100000...999999))"
        let food = Food(name: "Yogurt test aggiornato", per100: Nutrients(kcal: 61, protein: 10, carbs: 4, fat: 0.2),
                        portion: 150, portionName: "1 vasetto", barcode: code, brand: "Prova", source: .openFoodFacts)
        FoodStore.shared.upsert([food])
        XCTAssertEqual(FoodStore.shared.product(barcode: code)?.name, "Yogurt test aggiornato")
        XCTAssertTrue(FoodStore.shared.search("yogurt test aggiornato").contains { $0.barcode == code })
        XCTAssertGreaterThan(FoodStore.shared.updatedCount, 0)
    }
}

final class UpdateCheckerTests: XCTestCase {
    private let source = Data("""
        {"apps":[{"bundleIdentifier":"app.piatto.ios","versions":[
          {"version":"3.9","buildVersion":"18","localizedDescription":"novità"},
          {"version":"3.8","buildVersion":"17","localizedDescription":""}]}]}
        """.utf8)

    func testFindsNewerBuild() {
        let release = UpdateChecker.newest(in: source, newerThan: 17)
        XCTAssertEqual(release?.version, "3.9")
        XCTAssertEqual(release?.build, 18)
        XCTAssertEqual(release?.notes, "novità")
    }

    func testNothingWhenUpToDate() {
        XCTAssertNil(UpdateChecker.newest(in: source, newerThan: 18))
        XCTAssertNil(UpdateChecker.newest(in: Data("not json".utf8), newerThan: 1))
    }
}


final class DietTypeTests: XCTestCase {
    func testCarbCyclingMovesCarbsToTrainingDays() {
        var p = Profile(); p.manualKcal = 2400; p.diet = .carbCycling
        let train = Nutrition.goals(p, kind: .training), rest = Nutrition.goals(p, kind: .rest)
        XCTAssertGreaterThan(train.carbs, rest.carbs * 1.5)
        XCTAssertLessThan(train.fat, rest.fat)
        XCTAssertEqual((train.kcal * 4 + rest.kcal * 3) / 7, 2400, accuracy: 2)
    }

    func testEveryDietAddsUpToItsCalories() {
        for diet in Profile.Diet.allCases {
            var p = Profile(); p.manualKcal = 2400; p.diet = diet
            for kind in [DayKind.training, .rest] {
                let g = Nutrition.goals(p, kind: kind)
                XCTAssertEqual(g.protein * 4 + g.carbs * 4 + g.fat * 9, g.kcal, accuracy: g.kcal * 0.08, "\(diet) \(kind)")
            }
        }
    }

    func testKetoKeepsCarbsLow() {
        var p = Profile(); p.diet = .chetogenica
        XCTAssertLessThanOrEqual(Nutrition.goals(p, kind: .training).carbs, 30)
    }

    func testOldProfilesStillDecode() throws {
        let old = #"{"name":"","sex":"uomo","age":30,"heightCm":173,"weightKg":86,"targetKg":78,"goal":"ricomposizione","activity":"leggero","vegetarian":true,"trainingDays":4,"workoutKcal":300,"onboarded":true,"simpleMode":false,"useHealth":true,"reminders":true,"reminderTimes":{}}"#
        let p = try JSONDecoder().decode(Profile.self, from: Data(old.utf8))
        XCTAssertTrue(p.onboarded)
        XCTAssertEqual(p.diet, .bilanciata)
        XCTAssertEqual(p.trainingWeekdaySet, [2, 3, 5, 6])
    }
}

final class FoodGateTests: XCTestCase {
    func testComputerIsNotFood() {
        XCTAssertEqual(FoodGate.decide([("computer", 0.82), ("laptop", 0.7), ("electronics", 0.6)]), .notFood("un computer"))
    }

    func testBreadIsFood() {
        XCTAssertEqual(FoodGate.decide([("bread", 0.6), ("baked_goods", 0.7), ("table", 0.5)]), .food)
    }

    func testUnclearPhotoIsLeftToTheAI() {
        XCTAssertEqual(FoodGate.decide([("wood_processed", 0.3)]), .unsure)
    }
}

final class WorkoutTests: XCTestCase {
    func testMonthsOfTheCalendarCycle() {
        func d(_ day: Int, _ month: Int) -> Date { Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day))! }
        let cycle = Cycle.ciclo2
        XCTAssertEqual(Progression.phase(on: d(10, 9), cycle: cycle), .month(1))
        XCTAssertEqual(Progression.phase(on: d(4, 10), cycle: cycle), .month(2))
        XCTAssertEqual(Progression.phase(on: d(14, 10), cycle: cycle), .deload)
        XCTAssertEqual(Progression.phase(on: d(20, 10), cycle: cycle), .month(3))
        XCTAssertEqual(Progression.phase(on: d(20, 11), cycle: cycle), .finished)
    }

    func testSetsAndRepsByMonthAndRole() {
        let bench = Exercise(name: "Panca", pattern: "push_h", sets: 4, reps: "6–10", rir: "1–2", cue: "", stretch: "", role: .fondamentale)
        let fly = Exercise(name: "Croci", pattern: "fly", sets: 3, reps: "12–15", rir: "1", cue: "", stretch: "", role: .isolamento, dropset: "Dropset -25%")
        XCTAssertEqual(Progression.apply(bench, phase: .month(2)).reps, "8–10")
        XCTAssertEqual(Progression.apply(bench, phase: .month(3)).reps, "6–8")
        XCTAssertEqual(Progression.apply(bench, phase: .deload).sets, 3)
        XCTAssertNil(Progression.apply(fly, phase: .deload).dropset)
        XCTAssertEqual(Progression.apply(fly, phase: .month(3)).dropset, "Dropset -25% doppio")
    }

    func testCalendarEventIsParsed() {
        let event = CalendarProgram.ciclo2[0]
        let day = PlanParser.day(title: event.title, description: event.text)
        XCTAssertEqual(day?.name, "A1")
        XCTAssertEqual(day?.focus, "Petto/Schiena")
        XCTAssertEqual(day?.blocks.count, 3)
        XCTAssertEqual(day?.blocks[0].restSeconds, 90)
        XCTAssertEqual(day?.blocks[0].exercises.first?.name, "Panca piana manubri (neutra)")
        XCTAssertEqual(day?.blocks[0].exercises.first?.sets, 4)
        XCTAssertEqual(day?.blocks[0].exercises.first?.reps, "6–10")
        XCTAssertEqual(day?.blocks[0].exercises.first?.role, .fondamentale)
        XCTAssertEqual(day?.blocks[1].exercises.last?.dropset, "Dropset -20%")
        XCTAssertEqual(day?.blocks[1].exercises.last?.pattern, "pull_v")
        XCTAssertEqual(day?.blocks[2].exercises.last?.pattern, "pullover")
        XCTAssertEqual(day?.blocks[0].exercises.first?.busy, ["Chest press macchina"])
        let cycle = PlanParser.cycle(from: event.text, year: 2026, name: "Ciclo 2")
        XCTAssertEqual(cycle, Cycle.ciclo2)
    }

    func testAllFourCalendarDays() {
        let days = CalendarProgram.ciclo2.compactMap { PlanParser.day(title: $0.title, description: $0.text) }
        XCTAssertEqual(days.map(\.name), ["A1", "A2", "B1", "B2"])
        XCTAssertEqual(days.flatMap { $0.blocks.flatMap(\.exercises) }.filter { $0.dropset != nil }.count, 6)
        XCTAssertEqual(days[3].blocks[1].exercises[0].name, "Seated leg curl")
    }

    func testEveryPlanExerciseHasAlternatives() {
        for exercise in Preferences.personalize(WorkoutPlan.nomoredietDays + PlanStore.shared.calendarDays).flatMap({ $0.blocks.flatMap(\.exercises) }) {
            XCTAssertFalse(ExerciseSwaps.alternatives(for: exercise).isEmpty, exercise.name)
        }
    }

    func testTellingTheWorkout() {
        let sets = WorkoutTextParser.parse("panca 60 kg 4x8 e lat machine 55 kg 3 serie da 10")
        XCTAssertEqual(sets.count, 2)
        XCTAssertEqual(sets.first?.kg, 60)
        XCTAssertEqual(sets.first?.sets, 4)
        XCTAssertEqual(sets.first?.reps, 8)
        XCTAssertEqual(sets.last?.sets, 3)
        XCTAssertEqual(sets.last?.reps, 10)
        XCTAssertNotNil(ExerciseSwaps.match("lat machine"))
    }

    func testMealSlotFromTime() {
        func at(_ h: Int, _ m: Int) -> MealSlot { MealSlot.at(Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: .now)!) }
        XCTAssertEqual(at(7, 30), .colazione)
        XCTAssertEqual(at(10, 45), .spuntino)
        XCTAssertEqual(at(13, 0), .pranzo)
        XCTAssertEqual(at(16, 30), .spuntino)
        XCTAssertEqual(at(20, 0), .cena)
    }
}

final class RepDetectorTests: XCTestCase {
    /// 10 reps of 40 cm, 3 s each, with sensor noise.
    func testCountsSimulatedReps() {
        var detector = RepDetector()
        var reps = 0
        var generator = SystemRandomNumberGenerator()
        let dt = 1.0 / 50, period = 3.0, w = 2 * Double.pi / period
        var t = 0.0
        while t < 10 * period + 3 {
            let inRep = t >= 1 && t < 1 + 10 * period
            let a = inRep ? -0.2 * w * w * cos(w * (t - 1)) : 0
            let noise = Double.random(in: -0.15...0.15, using: &generator)
            if detector.add(a + noise + 0.05, dt: dt) { reps += 1 }
            t += dt
        }
        XCTAssertEqual(reps, 10, accuracy: 1)
    }

    func testStillPhoneCountsNothing() {
        var detector = RepDetector()
        var reps = 0
        for _ in 0..<1500 where detector.add(Double.random(in: -0.05...0.05), dt: 1.0 / 50) { reps += 1 }
        XCTAssertEqual(reps, 0)
    }
}

final class CoachChatTests: XCTestCase {
    func testGreetingNeverBecomesSets() {
        let invented = [ToldSets(exercise: "Hack squat", kg: 10, sets: 3, reps: 15, rir: nil)]
        XCTAssertTrue(CoachChat.validated(invented, against: "Ciao coach mi senti? come va").isEmpty)
    }

    func testRealSetsAreKept() {
        let told = [ToldSets(exercise: "Panca piana", kg: 60, sets: 4, reps: 8, rir: nil)]
        XCTAssertEqual(CoachChat.validated(told, against: "oggi panca 60 kg 4x8").count, 1)
    }
}

final class WeightPlanTests: XCTestCase {
    func testLosingWeightEatsBelowMaintenance() {
        var p = Profile()
        p.goal = .dimagrire
        p.weightKg = 86; p.targetKg = 80
        let plan = Nutrition.plan(p)
        XCTAssertEqual(plan.maintenance - plan.daily, 550, accuracy: 1)
        XCTAssertNotNil(plan.weeks)
        XCTAssertEqual(Double(plan.weeks ?? 0), 6 / 0.5, accuracy: 1)
    }

    func testHealthEnergyIsUsedForMaintenance() {
        var p = Profile(); p.healthTDEE = 2700
        XCTAssertEqual(Nutrition.maintenance(p), 2700)
        XCTAssertEqual(Nutrition.maintenanceSource(p), .health)
    }

    func testNeverBelowTheFloor() {
        var p = Profile(); p.goal = .dimagrire; p.lossPerWeek = 1.0; p.manualKcal = nil; p.healthTDEE = 1900
        XCTAssertGreaterThanOrEqual(Nutrition.dailyTarget(p), Nutrition.floor(p))
        XCTAssertTrue(Nutrition.plan(p).limited)
    }
}

final class PackageReaderTests: XCTestCase {
    func testKeepsProductNameDropsNutritionTable() {
        let lines = ["Yogurt Greco 0%", "Valori nutrizionali per 100 g", "Energia 230 kJ / 54 kcal", "Proteine 10 g", "500 g", "www.esempio.it", "Bianco naturale"]
        XCTAssertEqual(PackageReader.productLines(lines), ["Yogurt Greco 0%", "Bianco naturale"])
    }

    func testPrintedNameOfAFood() {
        XCTAssertTrue(PackageReader.namesFood(["Yogurt Greco 0%"]))
        XCTAssertFalse(PackageReader.namesFood(["MacBook Pro"]))
    }
}

final class KitchenScaleTests: XCTestCase {
    func testReadsGramsOnTheDisplay() {
        XCTAssertEqual(TextReader.kitchenGrams(["TARE", "152 g"]), 152)
        XCTAssertEqual(TextReader.kitchenGrams(["0,250 kg"]), 250)
        XCTAssertNil(TextReader.kitchenGrams(["Valori per 100 g"]))
        XCTAssertNil(TextReader.kitchenGrams(["12:30"]))
    }

    func testScaleWeightSplitsAcrossFoods() {
        let rice = FoodAI.Item(name: "Riso", grams: 150, per100: Nutrients(kcal: 130), confidence: "media")
        let peas = FoodAI.Item(name: "Piselli", grams: 50, per100: Nutrients(kcal: 80), confidence: "media")
        XCTAssertEqual(MealRecognizer.applyScale(240, to: [rice]).first?.grams, 240)
        XCTAssertEqual(MealRecognizer.applyScale(240, to: [rice, peas]).map(\.grams), [180, 60])
    }
}

final class DishClassifierTests: XCTestCase {
    func testDropsBackgroundAndWeakGuessesBestFirst() {
        let guesses = [DishClassifier.Guess(dish: "__background__", confidence: 0.6), .init(dish: "Lasagne", confidence: 0.2),
                       .init(dish: "Carbonara", confidence: 0.5), .init(dish: "Risotto", confidence: 0.05), .init(dish: "/g/11b8_rxx4d", confidence: 0.3)]
        XCTAssertEqual(DishClassifier.top(guesses).map(\.dish), ["Carbonara", "Lasagne"])
    }

    func testHintIsOnlyAClue() {
        XCTAssertEqual(DishClassifier.hint([]), "")
        let hint = DishClassifier.hint([.init(dish: "Carbonara", confidence: 0.62)])
        XCTAssertTrue(hint.contains("Carbonara 62%"))
        XCTAssertTrue(hint.contains("indizio"))
    }
}

final class ShortcutHealthTests: XCTestCase {
    override func tearDown() { ShortcutHealth.history = [:] }

    func testValuesFromShortcutsLookLikeAHealthReading() {
        ShortcutHealth.history = [:]
        let today = DayId.today
        for back in 1...8 {
            ShortcutHealth.record(day: DayId.shift(today, by: -back), values: ["steps": 8000, "activeKcal": 500, "basalKcal": 1800])
        }
        ShortcutHealth.record(day: today, values: ["steps": 3000, "weightKg": 84.6, "sleepHours": 7.5, "activeKcal": nil])
        let result = ShortcutHealth.result(today: today)
        let daily = result["daily"] as? [String: [String: Double]] ?? [:]
        XCTAssertEqual(daily["steps"]?[today], 3000)
        XCTAssertNil(daily["activeKcal"]?[today], "a field not sent is not a zero")
        XCTAssertEqual((result["weights"] as? [[String: Any]])?.first?["kg"] as? Double, 84.6)
        XCTAssertEqual((result["readiness"] as? [String: Double])?["sleepHours"], 7.5)
        let summary = HealthCache.summary(daily: daily, today: today)
        XCTAssertEqual(summary.steps, 8000)
        XCTAssertEqual(summary.tdee, 2300)
    }

    func testLaterValuesOfTheSameDayAreMerged() {
        ShortcutHealth.history = [:]
        let today = DayId.today
        ShortcutHealth.record(day: today, values: ["steps": 1000])
        ShortcutHealth.record(day: today, values: ["steps": 5000, "weightKg": 85])
        XCTAssertEqual(ShortcutHealth.history[today], ["steps": 5000, "weightKg": 85])
    }
}

final class ShortcutNumberTests: XCTestCase {
    func testNumbersInAnyLocale() {
        XCTAssertEqual(ShortcutHealth.number("8.532 passi", decimals: false), 8532)
        XCTAssertEqual(ShortcutHealth.number("8532", decimals: false), 8532)
        XCTAssertEqual(ShortcutHealth.number("1,790.5 kcal", decimals: false), 1790.5)
        XCTAssertEqual(ShortcutHealth.number("1.790,5", decimals: false), 1790.5)
        XCTAssertEqual(ShortcutHealth.number("512,3", decimals: false), 512.3)
        XCTAssertEqual(ShortcutHealth.number("84,6 kg", decimals: true), 84.6)
        XCTAssertEqual(ShortcutHealth.number("84.6", decimals: true), 84.6)
        XCTAssertEqual(ShortcutHealth.number("7,25", decimals: true), 7.25)
        XCTAssertNil(ShortcutHealth.number("", decimals: true))
    }

    func testHealthLinkRecordsToday() {
        ShortcutHealth.history = [:]
        defer { ShortcutHealth.history = [:] }
        ShortcutHealth.handle(URL(string: "nomorediet://health?steps=8.532&active=512&weight=84,6&unknown=3")!)
        XCTAssertEqual(ShortcutHealth.history[DayId.today], ["steps": 8532, "activeKcal": 512, "weightKg": 84.6])
    }
}

final class ShortcutAllMetricsTests: XCTestCase {
    func testEveryHealthValueReachesTheCard() {
        ShortcutHealth.history = [:]
        defer { ShortcutHealth.history = [:] }
        ShortcutHealth.handle(URL(string: "nomorediet://health?hr=72&hrv=48&vo2=41,5&fat=0,22&flights=9&rhr=58")!)
        let result = ShortcutHealth.result()
        let latest = result["latest"] as? [String: Double] ?? [:]
        XCTAssertEqual(latest["heartRateAvg"], 72)
        XCTAssertEqual(latest["vo2max"], 41.5)
        XCTAssertEqual(latest["bodyFat"], 22)
        XCTAssertEqual((result["readiness"] as? [String: Double])?["hrvToday"], 48)
        XCTAssertEqual((result["daily"] as? [String: [String: Double]])?["flights"]?[DayId.today], 9)
    }
}

final class ShortcutIntentTests: XCTestCase {
    func testSamplesBecomeOneValuePerDay() {
        typealias A = ShortcutHealth.Aggregate
        XCTAssertEqual(A.sum([1200, 3400, 800]), 5400)
        XCTAssertNil(A.sum([]))
        XCTAssertNil(A.sum(nil))
        XCTAssertEqual(A.mean([60, 80]), 70)
        XCTAssertEqual(A.latest([84.6]), 84.6)
        XCTAssertEqual(A.sleep([7.5]), 7.5)
        XCTAssertEqual(A.sleep([27000]), 7.5)
        XCTAssertEqual(A.sleep([450]), 7.5)
    }

    func testRunURLFallsBackToTheSecondName() {
        let url = ShortcutHealth.runURL(names: ["Nomorediet Salute", "Invia dati Salute a Nomorediet"])!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "name" }?.value, "Nomorediet Salute")
        let error = items.first { $0.name == "x-error" }!.value!
        let next = URLComponents(string: error)!.queryItems!
        XCTAssertEqual(next.first { $0.name == "name" }?.value, "Invia dati Salute a Nomorediet")
        XCTAssertEqual(next.first { $0.name == "x-error" }?.value, "nomorediet://diario")
    }
}

final class ProductTextTests: XCTestCase {
    func testPackTextBecomesASearch() {
        XCTAssertEqual(TextReader.productQuery("YOGURT GRECO 0%  500 g"), "Yogurt Greco 0%")
        XCTAssertEqual(TextReader.productQuery("Pan di Stelle"), "Pan di Stelle")
        XCTAssertEqual(TextReader.productQuery("  Mulino  Bianco\n1,5 kg "), "Mulino Bianco")
        XCTAssertEqual(TextReader.productQuery("350g"), "")
    }
}

final class QuickLogTests: XCTestCase {
    func testEstimatesFollowTheDayGoal() {
        let goals = Goals(kcal: 2000, protein: 150, carbs: 220, fat: 60, fiber: 30, iron: 0, calcium: 0, b12: 0, zinc: 0)
        XCTAssertEqual(QuickLog.estimate(.pranzo, .normale, goals: goals).kcal, 700)
        XCTAssertEqual(QuickLog.estimate(.colazione, .leggero, goals: goals).kcal, 260)
        XCTAssertEqual(QuickLog.estimate(.cena, .abbondante, goals: goals).kcal, 980)
        XCTAssertEqual(QuickLog.estimate(.pranzo, .normale, goals: goals).protein, 52.5, accuracy: 0.01)
        let day = MealSlot.allCases.reduce(0) { $0 + QuickLog.share($1) }
        XCTAssertEqual(day, 1, accuracy: 0.001)
    }
}

final class SetWaveTests: XCTestCase {
    private func d(_ day: Int, _ month: Int) -> Date { Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))! }

    func testThreeFourFiveThenAgain() {
        let start = d(5, 10) // a Monday
        XCTAssertEqual(SetWave.sets(on: d(5, 10), start: start), 3)
        XCTAssertEqual(SetWave.sets(on: d(11, 10), start: start), 3) // Sunday, same week
        XCTAssertEqual(SetWave.sets(on: d(13, 10), start: start), 4)
        XCTAssertEqual(SetWave.sets(on: d(21, 10), start: start), 5)
        XCTAssertEqual(SetWave.sets(on: d(26, 10), start: start), 3)
        XCTAssertEqual(SetWave.sets(on: d(28, 9), start: start), 5) // the week before the start
    }

    func testDeloadKeepsItsSets() {
        let e = Exercise(name: "Panca", pattern: "push_h", sets: 2, reps: "10", rir: "3+", cue: "", stretch: "")
        XCTAssertEqual(SetWave.apply(e, phase: .deload).sets, 2)
    }
}

final class WorkoutSequenceTests: XCTestCase {
    func testSkippedWorkoutIsStillNext() {
        let days = WorkoutPlan.days
        guard days.count >= 2, let first = days[0].blocks.first?.exercises.first?.name,
              let second = days[1].blocks.first?.exercises.first?.name else { return }
        // last session was day 1 on Monday; nothing on Tuesday (skipped): Wednesday is still day 2
        XCTAssertEqual(WorkoutPlan.current(logs: [(day: "2026-10-05", exercise: first)], today: "2026-10-07"), 1)
        // day 2 done today: today stays day 2
        XCTAssertEqual(WorkoutPlan.current(logs: [(day: "2026-10-05", exercise: first), (day: "2026-10-07", exercise: second)],
                                           today: "2026-10-07"), 1)
        // a choice made with the arrows wins, and wraps around
        XCTAssertEqual(WorkoutPlan.current(logs: [], today: "2026-10-07", pick: days.count), 0)
    }
}

final class HealthExportTests: XCTestCase {
    func testDailyValuesFromTheExport() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData locale="it_IT">
         <Record type="HKQuantityTypeIdentifierStepCount" sourceName="iPhone" unit="count" startDate="2026-10-05 08:00:00 +0200" endDate="2026-10-05 08:10:00 +0200" value="4000"/>
         <Record type="HKQuantityTypeIdentifierStepCount" sourceName="iPhone" unit="count" startDate="2026-10-05 18:00:00 +0200" endDate="2026-10-05 18:10:00 +0200" value="2000"/>
         <Record type="HKQuantityTypeIdentifierStepCount" sourceName="Apple Watch" unit="count" startDate="2026-10-05 08:00:00 +0200" endDate="2026-10-05 08:10:00 +0200" value="5500"/>
         <Record type="HKQuantityTypeIdentifierActiveEnergyBurned" sourceName="Apple Watch" unit="kJ" startDate="2026-10-05 09:00:00 +0200" endDate="2026-10-05 09:30:00 +0200" value="418.4"/>
         <Record type="HKQuantityTypeIdentifierBodyMass" sourceName="Bilancia" unit="kg" startDate="2026-10-05 07:00:00 +0200" endDate="2026-10-05 07:00:00 +0200" value="86.3"/>
         <Record type="HKQuantityTypeIdentifierBodyMass" sourceName="Bilancia" unit="kg" startDate="2024-01-10 07:00:00 +0200" endDate="2024-01-10 07:00:00 +0200" value="90"/>
         <Record type="HKQuantityTypeIdentifierBodyFatPercentage" sourceName="Bilancia" unit="%" startDate="2026-10-05 07:00:00 +0200" endDate="2026-10-05 07:00:00 +0200" value="0.22"/>
         <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="Apple Watch" unit="count/min" startDate="2026-10-05 10:00:00 +0200" endDate="2026-10-05 10:00:00 +0200" value="60"/>
         <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="Apple Watch" unit="count/min" startDate="2026-10-05 11:00:00 +0200" endDate="2026-10-05 11:00:00 +0200" value="80"/>
         <Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="Apple Watch" startDate="2026-10-05 23:30:00 +0200" endDate="2026-10-06 03:30:00 +0200" value="HKCategoryValueSleepAnalysisAsleepCore"/>
         <Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="Apple Watch" startDate="2026-10-06 03:30:00 +0200" endDate="2026-10-06 06:30:00 +0200" value="HKCategoryValueSleepAnalysisAsleepDeep"/>
         <Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="Apple Watch" startDate="2026-10-05 23:00:00 +0200" endDate="2026-10-06 07:00:00 +0200" value="HKCategoryValueSleepAnalysisInBed"/>
        </HealthData>
        """
        let s = HealthExportReader.read(xml: xml, since: "2026-01-01")
        let day = s.days["2026-10-05"] ?? [:]
        XCTAssertEqual(day["steps"], 6000) // iPhone 6000 vs Watch 5500: the larger source, not the sum
        XCTAssertEqual(day["activeKcal"] ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(day["weightKg"], 86.3)
        XCTAssertEqual(day["bodyFat"] ?? 0, 22, accuracy: 0.01)
        XCTAssertEqual(day["heartRate"], 70)
        XCTAssertEqual(s.days["2026-10-06"]?["sleepHours"] ?? 0, 7, accuracy: 0.01)
        XCTAssertNil(s.days["2024-01-10"]) // older than `since`: no daily values
        XCTAssertEqual(s.weights["2024-01-10"], 90) // but every weighing is kept
    }
}

final class ZipReaderTests: XCTestCase {
    /// A one-entry ZIP written by hand, with the entry compressed as raw deflate (what ZIP uses).
    private func zip(name: String, content: Data) throws -> Data {
        let deflated = try (content as NSData).compressed(using: .zlib) as Data
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        let nameData = Data(name.utf8)
        var out = Data()
        out += le32(0x04034b50) + le16(20) + le16(0) + le16(8) + le16(0) + le16(0) + le32(0)
        out += le32(deflated.count) + le32(content.count) + le16(nameData.count) + le16(0) + nameData + deflated
        let cd = out.count
        out += le32(0x02014b50) + le16(20) + le16(20) + le16(0) + le16(8) + le16(0) + le16(0) + le32(0)
        out += le32(deflated.count) + le32(content.count) + le16(nameData.count) + le16(0) + le16(0) + le16(0) + le16(0)
        out += le32(0) + le32(0) + nameData
        let cdSize = out.count - cd
        out += le32(0x06054b50) + le16(0) + le16(0) + le16(1) + le16(1) + le32(cdSize) + le32(cd) + le16(0)
        return out
    }

    func testExportXmlComesOutOfTheZip() throws {
        let xml = String(repeating: "<Record type=\"HKQuantityTypeIdentifierStepCount\" sourceName=\"iPhone\" unit=\"count\" startDate=\"2026-10-05 08:00:00 +0200\" endDate=\"2026-10-05 08:10:00 +0200\" value=\"100\"/>\n", count: 3000)
        let full = "<?xml version=\"1.0\"?>\n<HealthData>\n" + xml + "</HealthData>\n"
        let dir = FileManager.default.temporaryDirectory
        let zipURL = dir.appendingPathComponent("export-test.zip")
        try zip(name: "apple_health_export/export.xml", content: Data(full.utf8)).write(to: zipURL)
        let summary = HealthExportReader.read(file: zipURL, since: "2026-01-01")
        XCTAssertEqual(summary?.days["2026-10-05"]?["steps"], 300_000)
    }
}

final class MealSplitterTests: XCTestCase {
    func testMealsNamedInOneSentence() {
        let parts = MealSplitter.split("A colazione caffè e 2 fette biscottate, a pranzo 80 g di pasta al pesto e a cena una pizza margherita")
        XCTAssertEqual(parts.map(\.slot), [.colazione, .pranzo, .cena])
        XCTAssertEqual(parts[0].text, "caffè e 2 fette biscottate")
        XCTAssertEqual(parts[1].text, "80 g di pasta al pesto")
        XCTAssertEqual(parts[2].text, "una pizza margherita")
    }

    func testNoMealNameUsesTheTimeOfDay() {
        XCTAssertEqual(MealSplitter.split("200 g di riso e pollo"), [.init(slot: nil, text: "200 g di riso e pollo")])
    }

    func testIntroWordsAreDropped() {
        let parts = MealSplitter.split("Stamattina ho mangiato a colazione uno yogurt, poi a merenda una mela")
        XCTAssertEqual(parts, [.init(slot: .colazione, text: "uno yogurt"), .init(slot: .spuntino, text: "una mela")])
    }
}

final class LastDayExtrasTests: XCTestCase {
    func testShortLastSessionGetsMoreExercises() {
        let day = WorkoutDay(name: "B2", focus: "Femorali", blocks: [
            ExerciseBlock(label: "1", restSeconds: 120, exercises: [
                Exercise(name: "Stacco", pattern: "hinge", sets: 4, reps: "6–10", rir: "1", cue: "", stretch: ""),
                Exercise(name: "Affondi", pattern: "lunge", sets: 4, reps: "6–10", rir: "1", cue: "", stretch: "")])])
        let out = WorkoutPlan.withExtras([day])
        XCTAssertEqual(out.last?.blocks.flatMap(\.exercises).count, 6)
        XCTAssertTrue(out.last?.blocks.flatMap(\.exercises).contains { $0.name == "Leg curl singolo con ginocchio appoggiato" } == true)
    }
}

final class SetRulesTests: XCTestCase {
    func testFundamentalsWaveAndOthersCapped() {
        var first = Exercise(name: "Panca", pattern: "push_h", sets: 4, reps: "8–12", rir: "1", cue: "", stretch: "")
        first.role = .fondamentale
        var other = Exercise(name: "Alzate", pattern: "raise_l", sets: 4, reps: "12–20", rir: "1", cue: "", stretch: "")
        other.role = .isolamento
        let f = SetWave.apply(first, phase: .month(1))
        XCTAssertEqual(f.sets, SetWave.sets())
        XCTAssertEqual(f.reps, "6–10")
        let o = SetWave.apply(other, phase: .month(1))
        XCTAssertEqual(o.sets, 3)
        XCTAssertEqual(o.reps, "12–15")
        XCTAssertEqual(SetWave.capped("20", at: 15), "15")
        XCTAssertEqual(SetWave.capped("15–20", at: 15), "15")
        XCTAssertEqual(SetWave.capped("10–12", at: 15), "10–12")
    }
}

final class FoodMatchTests: XCTestCase {
    func testPlainRiceIsRiceNotRiceCakes() {
        let food = MealRecognizer.bestMatch(for: ["riso"], in: FoodDatabase.foods)
        XCTAssertEqual(food.map { FoodDatabase.normalize($0.name).hasPrefix("riso") }, true, "trovato \(food?.name ?? "niente")")
        XCTAssertEqual(MealRecognizer.bestMatch(for: ["gallette di riso"], in: FoodDatabase.foods)?.name, "Gallette di riso")
    }
}

final class PreferencesTests: XCTestCase {
    func testDislikedExercisesAreReplacedOrRemoved() {
        let day = WorkoutDay(name: "B2", focus: "", blocks: [
            ExerciseBlock(label: "1", restSeconds: 90, exercises: [
                Exercise(name: "AFFONDI CON MANUBRI", pattern: "lunge", sets: 4, reps: "6–10", rir: "1", cue: "", stretch: ""),
                Exercise(name: "REMATORE MANUBRIO un braccio", pattern: "pull_h", sets: 4, reps: "6–10", rir: "1", cue: "", stretch: "")]),
            ExerciseBlock(label: "2", restSeconds: 60, exercises: [
                Exercise(name: "Calf raise in piedi", pattern: "calf", sets: 3, reps: "12", rir: "1", cue: "", stretch: "")])])
        let out = Preferences.personalize([day])[0]
        XCTAssertEqual(out.blocks.count, 1)
        XCTAssertEqual(out.blocks[0].exercises.map(\.name), ["Leg press 45° singola", "Row singolo al cavo seduto"])
    }

    func testPlanHasNoDislikedExercises() {
        for e in WorkoutPlan.nomoredietDays.flatMap({ $0.blocks.flatMap(\.exercises) }) {
            XCTAssertFalse(Preferences.dislikes(e.name), e.name)
        }
        let swaps = ExerciseSwaps.alternatives(for: Exercise(name: "Leg press 45°", pattern: "squat", sets: 3, reps: "10", rir: "1", cue: "", stretch: ""))
        XCTAssertFalse(swaps.contains { Preferences.dislikes($0.name) })
    }
}

final class AlgorithmReviewTests: XCTestCase {
    func testPartialDaysDoNotLowerMaintenance() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let weights = (0..<15).map { (start.addingTimeInterval(Double($0) * 86400), 86.0) }  // weight stable
        // 7 complete days at 2400 kcal, 7 days with half the meals logged
        let intakes = Array(repeating: 2400.0, count: 7) + Array(repeating: 1100.0, count: 7) + Array(repeating: 2400.0, count: 3)
        let tdee = Nutrition.adaptiveTDEE(intakes: intakes, weights: weights, formula: 2500)
        XCTAssertEqual(tdee, 2400)
    }

    func testAdaptiveStaysNearTheFormula() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let weights = (0..<15).map { (start.addingTimeInterval(Double($0) * 86400), 86.0) }
        let tdee = Nutrition.adaptiveTDEE(intakes: Array(repeating: 1600.0, count: 14), weights: weights, formula: 2600)
        XCTAssertEqual(tdee, 2080)  // 2600 × 0.8, not 1600
    }

    func testDatabaseRankingPrefersTheFoodNamedFirst() {
        func f(_ name: String, _ brand: String? = nil) -> Food {
            Food(name: name, per100: Nutrients(kcal: 100), portion: 100, portionName: "100 g", barcode: nil, brand: brand, source: .openFoodFacts)
        }
        let ranked = FoodStore.rank([f("Gallette di riso"), f("Sorrisi al cacao"), f("Riso basmati, cotto"), f("Riso Gallo", "Gallo")], words: ["riso"])
        XCTAssertEqual(ranked.first?.name, "Riso basmati, cotto")
        XCTAssertEqual(ranked.last?.name, "Sorrisi al cacao")
    }
}


final class EquipmentTests: XCTestCase {
    func testEquipmentIsReadFromTheName() {
        XCTAssertEqual(Equipment.needs("Row singolo al cavo seduto"), [.cavi])
        XCTAssertEqual(Equipment.needs("Panca piana manubri presa neutra"), [.manubri])
        XCTAssertEqual(Equipment.needs("Lat machine presa neutra"), [.macchine])
        XCTAssertEqual(Equipment.needs("Leg press 45°"), [.macchine])
        XCTAssertEqual(Equipment.needs("Panca inclinata al multipower"), [.multipower])
        XCTAssertEqual(Equipment.needs("Trazioni alla sbarra"), [.sbarra])
        XCTAssertTrue(Equipment.needs("Piegamenti sulle braccia").isEmpty)
    }

    func testAdaptSwapsOnlyExercisesWithBusyEquipment() {
        let day = "2099-01-01"
        let plan = Progression.withRoles(Preferences.personalize(WorkoutPlan.nomoredietDays))[0]
        let exercises = plan.blocks.flatMap(\.exercises)
        defer { for e in exercises { ExerciseSwaps.set(nil, for: e.name, day: day) } }
        ExerciseSwaps.adapt(plan, busy: [.cavi], on: day)
        for e in exercises {
            let now = ExerciseSwaps.resolved(e, day: day)
            if Equipment.isFree(e.name, busy: [.cavi]) {
                XCTAssertEqual(now.name, e.name, "\(e.name) non doveva cambiare")
            } else if now.name != e.name {
                XCTAssertTrue(Equipment.isFree(now.name, busy: [.cavi]), "\(e.name) → \(now.name) usa ancora i cavi")
            }
        }
    }

    func testAlwaysSwapStaysOnOtherDays() {
        let option = ExerciseSwaps.Option(name: "Chest press alla macchina", pattern: "push_h", cue: "")
        defer { ExerciseSwaps.set(nil, for: "Test panca", day: "2099-01-02", always: true) }
        ExerciseSwaps.set(option, for: "Test panca", day: "2099-01-02", always: true)
        XCTAssertEqual(ExerciseSwaps.swap(for: "Test panca", day: "2099-02-10")?.name, "Chest press alla macchina")
        ExerciseSwaps.set(nil, for: "Test panca", day: "2099-01-02", always: true)
        XCTAssertNil(ExerciseSwaps.swap(for: "Test panca", day: "2099-02-10"))
    }
}

final class FoodUpdaterTests: XCTestCase {
    func testWaitsAfterAFailedUpdate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-8 * 86400)
        XCTAssertTrue(FoodUpdater.shouldUpdate(now: now, lastUpdate: nil, lastFailure: nil))
        XCTAssertTrue(FoodUpdater.shouldUpdate(now: now, lastUpdate: old, lastFailure: nil))
        XCTAssertFalse(FoodUpdater.shouldUpdate(now: now, lastUpdate: old, lastFailure: now.addingTimeInterval(-60)))
        XCTAssertTrue(FoodUpdater.shouldUpdate(now: now, lastUpdate: old, lastFailure: now.addingTimeInterval(-7 * 3600)))
        XCTAssertFalse(FoodUpdater.shouldUpdate(now: now, lastUpdate: now.addingTimeInterval(-86400), lastFailure: nil))
    }
}
