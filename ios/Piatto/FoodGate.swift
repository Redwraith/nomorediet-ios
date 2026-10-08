import UIKit
import Vision

/// First check on a meal photo, on the device and before any AI: Apple's image classifier says whether the
/// picture shows food at all. A computer, a phone or a desk is refused instead of being "recognised" as bread.
/// The AI engines get the same instruction (contains_food), so both layers must agree before items are listed.
enum FoodGate {
    enum Verdict: Equatable {
        case food
        /// No food, with what the photo seems to show (Italian).
        case notFood(String)
        /// The classifier is not sure: the AI decides.
        case unsure
    }

    /// Labels of Apple's classification taxonomy that mean food or drink.
    static let foodWords = ["food", "fruit", "vegetable", "bread", "baked", "dessert", "cake", "pastry", "cookie", "meal", "dish",
                            "salad", "pizza", "pasta", "noodle", "rice", "sandwich", "burger", "meat", "fish", "seafood", "egg",
                            "cheese", "yogurt", "cereal", "soup", "sushi", "snack", "chocolate", "candy", "drink", "beverage",
                            "coffee", "tea", "juice", "wine", "beer", "milk", "legume", "bean", "nut", "berry", "citrus", "apple",
                            "banana", "tomato", "potato", "breakfast", "lunch", "dinner", "plate", "bowl", "sauce", "icecream",
                            "carrot", "onion", "garlic", "grape", "lemon", "melon", "peach", "cherry", "strawberry", "avocado",
                            "broccoli", "lettuce", "spinach", "mushroom", "lentil", "chickpea", "tofu", "honey", "butter",
                            "pancake", "waffle", "donut", "doughnut", "muffin", "croissant", "taco", "burrito", "kebab", "steak",
                            "chicken", "pork", "beef", "sausage", "shrimp", "salmon", "tuna", "fries", "cracker", "biscuit", "pie"]

    /// Matches whole parts of a taxonomy identifier ("baked_goods" → "baked", "goods"): short words must be equal,
    /// longer ones may be a prefix ("vegetables"), so "car" never matches "carrot" and "tea" never "steam".
    static func matches(_ identifier: String, _ word: String) -> Bool {
        identifier.lowercased().split(whereSeparator: { !$0.isLetter }).contains { part in
            part == word || word.count >= 4 && part.hasPrefix(word)
        }
    }

    /// Common non-food subjects, in Italian for the message.
    static let names: [String: String] = [
        "computer": "un computer", "laptop": "un portatile", "keyboard": "una tastiera", "computer_keyboard": "una tastiera",
        "monitor": "uno schermo", "screen": "uno schermo", "display": "uno schermo", "television": "un televisore",
        "phone": "un telefono", "cellphone": "un telefono", "smartphone": "un telefono", "electronics": "un dispositivo elettronico",
        "mouse": "un mouse", "desk": "una scrivania", "furniture": "un mobile", "chair": "una sedia", "table": "un tavolo",
        "people": "una persona", "person": "una persona", "adult": "una persona", "face": "un volto", "selfie": "un selfie",
        "dog": "un cane", "cat": "un gatto", "animal": "un animale", "car": "un'auto", "vehicle": "un veicolo",
        "document": "un documento", "paper": "un foglio", "book": "un libro", "text": "del testo", "clothing": "dei vestiti",
        "shoes": "delle scarpe", "room": "una stanza", "wall": "un muro", "floor": "il pavimento", "sky": "il cielo",
        "plant": "una pianta", "tree": "un albero", "building": "un edificio", "structure": "un edificio", "toy": "un giocattolo",
    ]

    static func check(_ image: UIImage) async -> Verdict {
        guard let cg = image.cgImage else { return .unsure }
        return await Task.detached(priority: .userInitiated) { () -> Verdict in
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cg, orientation: CGImagePropertyOrientation(image.imageOrientation))
            guard (try? handler.perform([request])) != nil, let results = request.results else { return .unsure }
            let labels = results.filter { $0.confidence > 0.05 }.map { ($0.identifier, Double($0.confidence)) }
            let verdict = decide(labels)
            DebugLog.shared.add("info", "ai", "Classificatore foto: \(labels.prefix(5).map { "\($0.0) \(Int($0.1 * 100))%" }.joined(separator: ", ")) → \(verdict)")
            return verdict
        }.value
    }

    /// Food when any food label reaches 15%; no food when a known non-food subject is clear (≥ 35%)
    /// and at least four times stronger than any food label.
    static func decide(_ labels: [(String, Double)]) -> Verdict {
        func isFood(_ id: String) -> Bool { foodWords.contains { matches(id, $0) } }
        let foodScore = labels.filter { isFood($0.0) }.map(\.1).max() ?? 0
        if foodScore >= 0.15 { return .food }
        let subject = labels.filter { !isFood($0.0) }.sorted { $0.1 > $1.1 }
            .first { label in names.keys.contains { matches(label.0, $0) || label.0.lowercased() == $0 } }
        if let subject, subject.1 >= 0.35, subject.1 >= foodScore * 4 {
            let key = names.keys.first { subject.0.lowercased() == $0 } ?? names.keys.filter { matches(subject.0, $0) }.max { $0.count < $1.count } ?? ""
            return .notFood(names[key] ?? "un oggetto")
        }
        return .unsure
    }
}
