import SwiftUI
import UIKit
import Vision
import VisionKit

/// Packaged foods from Open Food Facts (free, no account): barcode lookup and text search.
enum OpenFoodFacts {
    private struct ProductResponse: Decodable { let product: Product? }
    private struct SearchResponse: Decodable { let products: [Product]? }
    private struct Product: Decodable {
        let code: String?
        let product_name: String?
        let product_name_it: String?
        let brands: String?
        let serving_quantity: FlexibleDouble?
        let nutriments: [String: FlexibleDouble]?
        let last_modified_t: FlexibleDouble?
    }
    /// Open Food Facts sends numbers either as numbers or as strings.
    private struct FlexibleDouble: Decodable {
        let value: Double?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { value = d }
            else if let s = try? c.decode(String.self) { value = s.italianDouble }
            else { value = nil }
        }
    }

    private static func food(_ p: Product) -> Food? {
        guard let n = p.nutriments, let kcal = n["energy-kcal_100g"]?.value ?? (n["energy_100g"]?.value).map({ $0 / 4.184 }) else { return nil }
        let name = [p.product_name_it, p.product_name].compactMap { $0 }.first { !$0.isEmpty } ?? "Prodotto"
        let v = { (key: String) in n[key]?.value ?? 0 }
        let per100 = Nutrients(kcal: kcal, protein: v("proteins_100g"), carbs: v("carbohydrates_100g"), fat: v("fat_100g"),
                               fiber: v("fiber_100g"), iron: v("iron_100g") * 1000, calcium: v("calcium_100g") * 1000,
                               b12: v("vitamin-b12_100g") * 1_000_000, zinc: v("zinc_100g") * 1000)
        let portion = p.serving_quantity?.value ?? 100
        return Food(name: name, per100: per100, portion: portion > 0 ? portion : 100,
                    portionName: portion > 0 && portion != 100 ? "1 porzione" : "100 g",
                    barcode: p.code, brand: p.brands?.split(separator: ",").first.map(String.init), source: .openFoodFacts)
    }

    private static var session: URLSession {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": "Nomorediet-iOS/3.0 (personal app)"]
        config.timeoutIntervalForRequest = 12
        return URLSession(configuration: config)
    }

    static func product(barcode: String) async throws -> Food? {
        let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(barcode).json")!
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode(ProductResponse.self, from: data).product.flatMap(food)
    }

    /// Products sold in Italy, most recently modified first (for the weekly over-the-air database update).
    /// Returns the foods with nutrition facts and the oldest modification time on the page.
    static func recentlyModifiedInItaly(page: Int) async throws -> (foods: [Food], oldest: Double?) {
        var c = URLComponents(string: "https://world.openfoodfacts.org/api/v2/search")!
        c.queryItems = [URLQueryItem(name: "countries_tags_en", value: "italy"), URLQueryItem(name: "sort_by", value: "last_modified_t"),
                        URLQueryItem(name: "page_size", value: "100"), URLQueryItem(name: "page", value: String(page)),
                        URLQueryItem(name: "fields", value: "code,product_name,product_name_it,brands,serving_quantity,nutriments,last_modified_t")]
        let (data, _) = try await session.data(from: c.url!)
        let products = try JSONDecoder().decode(SearchResponse.self, from: data).products ?? []
        let oldest = products.compactMap { $0.last_modified_t?.value }.min()
        let foods = products.compactMap(food).filter { $0.per100.kcal >= 0 && $0.per100.kcal <= 950 && $0.barcode != nil }
        return (foods, oldest)
    }

    static func search(_ text: String) async throws -> [Food] {
        var c = URLComponents(string: "https://it.openfoodfacts.org/cgi/search.pl")!
        c.queryItems = [URLQueryItem(name: "search_terms", value: text), URLQueryItem(name: "search_simple", value: "1"),
                        URLQueryItem(name: "action", value: "process"), URLQueryItem(name: "json", value: "1"),
                        URLQueryItem(name: "page_size", value: "20"),
                        URLQueryItem(name: "fields", value: "code,product_name,product_name_it,brands,serving_quantity,nutriments")]
        let (data, _) = try await session.data(from: c.url!)
        return (try JSONDecoder().decode(SearchResponse.self, from: data).products ?? []).compactMap(food)
    }
}

/// Text recognition on a photo (on the iPhone, no internet): nutrition labels and scale displays.
enum TextReader {
    static func lines(in image: UIImage) async -> [String] {
        guard let cg = image.cgImage else { return [] }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .sorted { $0.boundingBox.minY > $1.boundingBox.minY }
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["it-IT", "en-US"]
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: cg, orientation: CGImagePropertyOrientation(image.imageOrientation))
            DispatchQueue.global(qos: .userInitiated).async {
                do { try handler.perform([request]) } catch { continuation.resume(returning: []) }
            }
        }
    }

    /// Values per 100 g from a nutrition label. Only fields it is confident about are filled.
    static func label(_ lines: [String]) -> Nutrients {
        var n = Nutrients()
        let text = lines.map { FoodDatabase.normalize($0) }
        func number(after keys: [String], unit: String? = nil) -> Double? {
            for (i, line) in text.enumerated() where keys.contains(where: { line.contains($0) }) {
                // the value is on the same line or on the next one
                for candidate in [line, i + 1 < text.count ? text[i + 1] : ""] {
                    if let unit, let v = firstNumber(in: candidate, before: unit) { return v }
                    if unit == nil, let v = numbers(in: candidate).first { return v }
                }
            }
            return nil
        }
        n.kcal = number(after: ["energia", "energy", "valore energetico"], unit: "kcal") ?? 0
        n.fat = number(after: ["grassi", "fat", "lipidi"]) ?? 0
        n.carbs = number(after: ["carboidrati", "carbohydrate"]) ?? 0
        n.protein = number(after: ["proteine", "protein"]) ?? 0
        n.fiber = number(after: ["fibre", "fibra", "fibres", "fiber"]) ?? 0
        if n.kcal == 0 { n.kcal = n.protein * 4 + n.carbs * 4 + n.fat * 9 }
        return n
    }

    /// Body weight on a scale display: the most plausible number between 30 and 250 kg.
    static func scaleWeight(_ lines: [String]) -> Double? {
        // clock times ("12:30") and percentages ("23,5%") on the display are not the weight
        let noise = try! NSRegularExpression(pattern: "\\d{1,2}:\\d{2}|\\d+(?:[.,]\\d+)?\\s*%")
        let cleaned = lines.map { line in
            noise.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: " ")
        }
        return cleaned.flatMap(numbers).filter { $0 >= 30 && $0 <= 250 }.max { a, b in
            // prefer numbers with one decimal, as scales show them
            (a.truncatingRemainder(dividingBy: 1) != 0 ? 1 : 0) < (b.truncatingRemainder(dividingBy: 1) != 0 ? 1 : 0)
        }
    }

    /// Weight shown by a kitchen scale in a meal photo: a number with "g" or "kg" on the display (1 g – 5 kg).
    static func kitchenGrams(_ lines: [String]) -> Double? {
        let re = try! NSRegularExpression(pattern: "(\\d+(?:[.,]\\d+)?)\\s*(kg|g|gr)\\b", options: .caseInsensitive)
        for line in lines {
            let ns = line as NSString
            for m in re.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                guard let value = ns.substring(with: m.range(at: 1)).italianDouble else { continue }
                let grams = ns.substring(with: m.range(at: 2)).lowercased() == "kg" ? value * 1000 : value
                // a lone "100 g" is usually the nutrition table header, not a scale
                if grams >= 1, grams <= 5000, !(grams == 100 && line.lowercased().contains("per")) { return grams.rounded() }
            }
        }
        return nil
    }

    static func numbers(in s: String) -> [Double] {
        let pattern = try! NSRegularExpression(pattern: "\\d+(?:[.,]\\d+)?")
        let ns = s as NSString
        return pattern.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { ns.substring(with: $0.range).italianDouble }
    }

    private static func firstNumber(in s: String, before unit: String) -> Double? {
        let pattern = try! NSRegularExpression(pattern: "(\\d+(?:[.,]\\d+)?)\\s*" + unit)
        let ns = s as NSString
        guard let m = pattern.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1)).italianDouble
    }
}

extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

/// Live barcode scanner (VisionKit). Calls `found` once with the first EAN/UPC code.
struct BarcodeScanner: UIViewControllerRepresentable {
    var found: (String) -> Void

    static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce, .code128])],
                                                qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case .barcode(let code) in items {
                if let value = code.payloadStringValue {
                    done = true
                    scanner.stopScanning()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    found(value)
                    return
                }
            }
        }
    }
}

/// System camera for one photo.
struct CameraPicker: UIViewControllerRepresentable {
    var done: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}

extension UIImage {
    /// Small JPEG for storing with a meal.
    func thumbnailJPEG(maxSide: CGFloat = 900) -> Data? {
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let image = UIGraphicsImageRenderer(size: target).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
        return image.jpegData(compressionQuality: 0.75)
    }
}
