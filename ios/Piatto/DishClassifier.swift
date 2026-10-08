import CoreML
import UIKit
import Vision

/// On-device dish recogniser: Google's AIY food classifier V1 (MobileNet, 2,023 dishes, Apache-2.0), converted to
/// Core ML in CI. A second opinion next to the AI (a hint in the prompt), proof that a photo shows food, and an
/// offline answer when no AI engine is connected. The app works without it if the model is not in the bundle.
enum DishClassifier {
    struct Guess: Equatable {
        let dish: String
        let confidence: Float
    }

    private static let model: VNCoreMLModel? = {
        guard let url = Bundle.main.url(forResource: "FoodClassifier", withExtension: "mlmodelc"),
              let ml = try? MLModel(contentsOf: url) else { return nil }
        return try? VNCoreMLModel(for: ml)
    }()

    static var isAvailable: Bool { model != nil }

    /// The likeliest dishes, best first (background dropped).
    static func classify(_ image: UIImage) async -> [Guess] {
        guard let model, let cg = image.cgImage else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let request = VNCoreMLRequest(model: model)
            request.imageCropAndScaleOption = .centerCrop
            try? VNImageRequestHandler(cgImage: cg, orientation: CGImagePropertyOrientation(image.imageOrientation)).perform([request])
            let results = request.results as? [VNClassificationObservation] ?? []
            return top(results.map { Guess(dish: $0.identifier, confidence: $0.confidence) })
        }.value
    }

    /// Best five over 8 %, without the background class and the few dishes that only have an id ("/g/…").
    static func top(_ guesses: [Guess]) -> [Guess] {
        guesses.filter { !$0.dish.hasPrefix("__") && !$0.dish.hasPrefix("/") && !$0.dish.isEmpty && $0.confidence >= 0.08 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(5).map { $0 }
    }

    /// The sentence for the AI: only a clue, the photo decides.
    static func hint(_ guesses: [Guess]) -> String {
        guard !guesses.isEmpty else { return "" }
        return "Un riconoscitore di piatti sul telefono (2.000 piatti) suggerisce: " +
            guesses.prefix(3).map { "\($0.dish) \(Int($0.confidence * 100))%" }.joined(separator: ", ") +
            ". È solo un indizio: fidati di quello che vedi."
    }
}

