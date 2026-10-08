import Foundation
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Free meal analysis with Apple's on-device model (Foundation Models, iOS 27+ with Apple Intelligence).
/// The photo never leaves the iPhone. The small on-device model recognises the foods and estimates grams;
/// nutrients come from the built-in food table when the food is there, from the model otherwise.
enum OnDeviceAI {
    /// Why the on-device model can't be used right now, or nil when it can.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 27, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return "Questo iPhone non supporta Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled): return "Attiva Apple Intelligence in Impostazioni → Apple Intelligence e Siri."
            case .unavailable(.modelNotReady): return "Il modello di Apple si sta ancora scaricando: riprova tra qualche minuto."
            case .unavailable: return "Il modello di Apple non è disponibile."
            }
        }
        return "Serve iOS 27."
        #else
        return "Questa versione dell'app è stata compilata senza il modello di Apple."
        #endif
    }

    static var isAvailable: Bool { unavailableReason == nil }

    /// Apple step of `MealRecognizer`. The small on-device model lists foods, cooking state, grams and alternative
    /// names; matching to the food table happens afterwards with multi-query search, since the full catalog
    /// does not fit its 8K context next to a photo.
    @MainActor static func recognize(_ input: MealRecognizer.Input, corrections: [String])
        async throws -> (dish: String, items: [MealRecognizer.Raw], note: String) {
        #if canImport(FoundationModels)
        if #available(iOS 27, *) {
            guard isAvailable else { throw FoodAI.Failure.server(unavailableReason ?? "modello non disponibile") }
            let guardian = AIGuard.shared
            try guardian.begin(costly: false)
            defer { guardian.end() }
            var outcome = "errore"
            defer { guardian.record(inputTokens: 0, outputTokens: 0, outcome: "Apple · " + outcome, costUSD: 0) }

            let request = MealRecognizer.userText(input, corrections: Array(corrections.suffix(4)))
                + " Elenca ogni alimento con i grammi; per ciascuno dai anche un nome alternativo in italiano e il nome generico in inglese."
            let session = LanguageModelSession(instructions: """
                Sei il nutrizionista di un'app italiana per contare le calorie. Riconosci ogni alimento in una foto \
                o in una descrizione di un pasto e stimi quanto pesa, usando piatto e posate come riferimento o le \
                quantità dette. Usa nomi italiani semplici e generici, indicando se è cotto o crudo. \
                I valori nutrizionali sono per 100 g dell'alimento così come è nel piatto. \
                Prima di tutto controlla che ci sia davvero cibo: computer, tastiere, telefoni, schermi, mobili, \
                persone, animali e stanze NON sono cibo, anche se colori o forme ricordano un alimento. \
                In quel caso containsFood è false, items è vuoto e in note scrivi cosa vedi. Non inventare mai alimenti.
                """)
            let response: LanguageModelSession.Response<OnDeviceMeal>
            do {
                if let image = input.image {
                    let photo = image.resizedForClaude(maxSide: 1024)
                    response = try await session.respond(generating: OnDeviceMeal.self) {
                        request
                        Attachment(photo)
                    }
                } else {
                    response = try await session.respond(generating: OnDeviceMeal.self) { request }
                }
            } catch {
                outcome = "errore modello"
                DebugLog.shared.add("error", "ai", "Modello Apple: \(error)")
                throw FoodAI.Failure.server("il modello di Apple non è riuscito ad analizzare il pasto. Riprova o aggiungi a mano.")
            }
            let meal = response.content
            if !meal.containsFood || meal.items.isEmpty && input.image != nil {
                outcome = "nessun cibo"
                throw FoodAI.Failure.notFood(meal.note)
            }
            let items = meal.items.map { food in
                MealRecognizer.Raw(name: food.name, description: food.alternatives.joined(separator: " "),
                                   nameEn: food.alternatives.last ?? "", grams: food.grams,
                                   per100: Nutrients(kcal: food.kcalPer100g, protein: food.proteinPer100g, carbs: food.carbsPer100g,
                                                     fat: food.fatPer100g, fiber: food.fiberPer100g),
                                   confidence: "bassa")
            }
            outcome = items.isEmpty ? "nessun cibo" : "ok"
            MealRecognizer.aiScaleGrams = meal.scaleGrams
            return (meal.dish, items, meal.note)
        }
        #endif
        throw FoodAI.Failure.server(unavailableReason ?? "modello non disponibile")
    }
}

#if canImport(FoundationModels)
@available(iOS 27, *)
@Generable
struct OnDeviceMeal {
    @Guide(description: "true solo se nella foto o nel testo ci sono davvero cibo o bevande; false per oggetti, schermi, computer, persone, animali")
    var containsFood: Bool
    @Guide(description: "Nome breve del piatto in italiano, oppure vuoto se non c'è cibo")
    var dish: String
    @Guide(description: "Grammi letti sul display di una bilancia da cucina nella foto (kg × 1000), 0 se non c'è")
    var scaleGrams: Double
    @Guide(description: "Ogni alimento visibile nel piatto")
    var items: [OnDeviceFood]
    @Guide(description: "Se non c'è cibo: cosa si vede. Altrimenti una frase su cosa potrebbe rendere imprecisa la stima, oppure vuoto")
    var note: String
}

@available(iOS 27, *)
@Generable
struct OnDeviceFood {
    @Guide(description: "Nome generico italiano dell'alimento")
    var name: String
    @Guide(description: "Due nomi alternativi: un sinonimo italiano e poi il nome generico in inglese")
    var alternatives: [String]
    @Guide(description: "Grammi stimati nel piatto")
    var grams: Double
    @Guide(description: "Chilocalorie per 100 g")
    var kcalPer100g: Double
    @Guide(description: "Grammi di proteine per 100 g")
    var proteinPer100g: Double
    @Guide(description: "Grammi di carboidrati per 100 g")
    var carbsPer100g: Double
    @Guide(description: "Grammi di grassi per 100 g")
    var fatPer100g: Double
    @Guide(description: "Grammi di fibre per 100 g")
    var fiberPer100g: Double
}
#endif
