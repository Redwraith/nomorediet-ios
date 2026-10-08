import UIKit
import Vision

/// Reads a food photo like a packaged product: barcode first (EAN/UPC), then the text printed on the pack
/// (product name, type). A barcode is looked up in the database; the text helps the AI name the product.
enum PackageReader {
    struct Result {
        var barcode: String?
        /// Lines that look like a product name or type, biggest-looking first.
        var lines: [String]
        /// Grams on the display of a kitchen scale in the photo.
        var scaleGrams: Double? = nil
    }

    static func read(_ image: UIImage) async -> Result {
        async let code = barcode(in: image)
        async let text = TextReader.lines(in: image)
        let lines = await text
        return Result(barcode: await code, lines: productLines(lines), scaleGrams: TextReader.kitchenGrams(lines))
    }

    static func barcode(in image: UIImage) async -> String? {
        guard let cg = image.cgImage else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> String? in
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.ean13, .ean8, .upce, .code128, .itf14]
            let handler = VNImageRequestHandler(cgImage: cg, orientation: CGImagePropertyOrientation(image.imageOrientation))
            try? handler.perform([request])
            return request.results?
                .filter { $0.confidence > 0.5 }
                .compactMap(\.payloadStringValue)
                .first { $0.count >= 8 && $0.allSatisfy(\.isNumber) }
        }.value
    }

    /// Keeps lines with real words, dropping nutrition tables, weights, addresses and legal text.
    static func productLines(_ lines: [String]) -> [String] {
        let skip = ["energia", "kcal", "kj", "grassi", "carboidrati", "proteine", "sale", "fibre", "zuccheri", "valori", "ingredienti",
                    "conservare", "scadenza", "consumarsi", "prodotto in", "lotto", "www", "http", "tel", "via ", "s.p.a", "srl", "peso netto"]
        var seen = Set<String>()
        return lines.compactMap { line -> String? in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = text.lowercased()
            let letters = text.filter(\.isLetter).count
            guard letters >= 4, letters * 2 >= text.count, text.count <= 40,
                  !skip.contains(where: { lower.hasPrefix($0) || lower.contains(" \($0)") && $0.count > 3 }),
                  seen.insert(lower).inserted else { return nil }
            return text
        }
        .prefix(6).map { $0 }
    }

    /// True when the printed words name a known food (the pack is food even if it does not look like a dish).
    static func namesFood(_ lines: [String]) -> Bool {
        lines.contains { line in
            FoodDatabase.normalize(line).split(separator: " ").contains { word in
                word.count >= 4 && !FoodDatabase.search(String(word)).isEmpty
            }
        }
    }
}
