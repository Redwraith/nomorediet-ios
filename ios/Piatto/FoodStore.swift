import Foundation
import SQLite3

/// The large food database: the copy bundled with the app (products sold in Italy from Open Food Facts and
/// generic foods and dishes from USDA FoodData Central, built by `scripts/build_food_db.py`) plus a writable
/// "updates" database that the app fills over the air (`FoodUpdater`) and with products looked up online.
/// Searched on the device, works offline.
final class FoodStore {
    static let shared = FoodStore()

    fileprivate var db: OpaquePointer?
    /// Writable: products updated over the air or found online after the bundled copy was built.
    fileprivate var updates: OpaquePointer?
    private let queue = DispatchQueue(label: "foodstore")
    /// Number of foods and the date of the weekly build, for Profile.
    private(set) var count = 0
    private(set) var built: String?

    var isAvailable: Bool { db != nil || updates != nil }
    /// Products received over the air.
    var updatedCount: Int { updates.map { _ in rows(on: \.updates, "SELECT count(*) FROM foods", []) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0 } ?? 0 }

    private init() {
        openUpdates()
        guard let url = Bundle.main.url(forResource: "foods", withExtension: "sqlite"),
              sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            db = nil
            return
        }
        let meta = rows(on: \.db, "SELECT key, value FROM meta", []) { stmt in (Self.text(stmt, 0), Self.text(stmt, 1)) }
        for (key, value) in meta {
            if key == "count" { count = Int(value) ?? 0 }
            if key == "built" { built = value }
        }
        DebugLog.shared.add("info", "db", "Database alimenti: \(count) voci, aggiornato al \(built ?? "?")")
    }

    /// Foods whose name (and brand) contain every word typed, shortest names first.
    func search(_ text: String, limit: Int = 40) -> [Food] {
        let words = FoodDatabase.normalize(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 2 }.prefix(5)
        guard isAvailable, !words.isEmpty else { return [] }
        let clause = words.map { _ in "norm LIKE ?" }.joined(separator: " AND ")
        // a wider set of candidates, ranked below: names starting with the first word first ("riso …" before "gallette di riso")
        let sql = "SELECT \(Self.columns) FROM foods WHERE \(clause) ORDER BY (norm LIKE ?) DESC, length(norm) LIMIT \(limit * 4)"
        let args = words.map { "%\($0)%" } + ["\(words[0])%"]
        // updated products replace the bundled copy of the same barcode
        let fresh = rows(on: \.updates, sql, args, Self.food)
        let codes = Set(fresh.compactMap(\.barcode))
        let bundled = rows(on: \.db, sql, args, Self.food).filter { $0.barcode == nil || !codes.contains($0.barcode!) }
        return Array(Self.rank(fresh + bundled, words: Array(words)).prefix(limit))
    }

    /// Best first: every word as a whole word, the name starting with the first word, generic foods before brands,
    /// then the shortest name. Substring hits inside other words ("riso" in "sorriso") go last.
    static func rank(_ foods: [Food], words: [String]) -> [Food] {
        func score(_ food: Food) -> Double {
            let name = FoodDatabase.normalize(food.name)
            let tokens = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let whole = words.filter { w in tokens.contains { $0 == w || ($0.hasPrefix(w) && $0.count <= w.count + 2) } }.count
            var s = Double(whole) / Double(max(words.count, 1)) * 4
            if tokens.first.map({ $0.hasPrefix(words[0]) }) == true { s += 2 }
            if food.brand == nil || food.brand?.isEmpty == true { s += 1 }
            s -= Double(name.count) / 60
            return s
        }
        return foods.map { ($0, score($0)) }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    func product(barcode: String) -> Food? {
        let sql = "SELECT \(Self.columns) FROM foods WHERE code = ? LIMIT 1"
        return rows(on: \.updates, sql, [barcode], Self.food).first ?? rows(on: \.db, sql, [barcode], Self.food).first
    }

    // MARK: Updates database

    private func openUpdates() {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("food-updates.sqlite").path
        guard sqlite3_open_v2(path, &updates, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            updates = nil
            return
        }
        exec("""
            CREATE TABLE IF NOT EXISTS foods (norm TEXT NOT NULL, name TEXT NOT NULL, brand TEXT, code TEXT PRIMARY KEY, src TEXT NOT NULL,
                kcal REAL, protein REAL, carbs REAL, fat REAL, fiber REAL, iron REAL, calcium REAL, b12 REAL, zinc REAL,
                portion REAL, portion_name TEXT, updated REAL);
            """)
    }

    /// Adds or replaces products (by barcode) in the updates database.
    func upsert(_ foods: [Food]) {
        let sql = "INSERT OR REPLACE INTO foods VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
        queue.sync {
            guard let updates else { return }
            sqlite3_exec(updates, "BEGIN", nil, nil, nil)
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(updates, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
            defer { sqlite3_finalize(stmt); sqlite3_exec(updates, "COMMIT", nil, nil, nil) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for f in foods {
                guard let code = f.barcode, !code.isEmpty else { continue }
                sqlite3_reset(stmt)
                let texts = [FoodDatabase.normalize("\(f.name) \(f.brand ?? "")"), f.name, f.brand ?? "", code, "OFF"]
                for (i, t) in texts.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), t, -1, transient) }
                let n = f.per100
                for (i, v) in [n.kcal, n.protein, n.carbs, n.fat, n.fiber, n.iron, n.calcium, n.b12, n.zinc, f.portion].enumerated() {
                    sqlite3_bind_double(stmt, Int32(i + 6), v)
                }
                sqlite3_bind_text(stmt, 16, f.portionName, -1, transient)
                sqlite3_bind_double(stmt, 17, Date().timeIntervalSince1970)
                sqlite3_step(stmt)
            }
        }
    }

    private func exec(_ sql: String) {
        queue.sync { if let updates { sqlite3_exec(updates, sql, nil, nil, nil) } }
    }

    // MARK: SQLite

    private static let columns = "name, brand, code, src, kcal, protein, carbs, fat, fiber, iron, calcium, b12, zinc, portion, portion_name"

    private static func food(_ s: OpaquePointer) -> Food {
        let d = { (i: Int32) in sqlite3_column_double(s, i) }
        let brand = text(s, 1)
        return Food(name: text(s, 0),
                    per100: Nutrients(kcal: d(4), protein: d(5), carbs: d(6), fat: d(7), fiber: d(8),
                                      iron: d(9), calcium: d(10), b12: d(11), zinc: d(12)),
                    portion: d(13) > 0 ? d(13) : 100, portionName: text(s, 14).isEmpty ? "100 g" : text(s, 14),
                    barcode: text(s, 2).isEmpty ? nil : text(s, 2), brand: brand.isEmpty ? nil : brand,
                    source: text(s, 3) == "OFF" ? .openFoodFacts : .database)
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
    }

    private func rows<T>(on which: KeyPath<FoodStore, OpaquePointer?>, _ sql: String, _ args: [String], _ map: (OpaquePointer) -> T) -> [T] {
        queue.sync {
            guard let db = self[keyPath: which] else { return [] }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (i, arg) in args.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), arg, -1, transient) }
            var out: [T] = []
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(map(stmt)) }
            return out
        }
    }
}
