import CryptoKit
import Foundation
import SQLite3

/// Main-thread use only.
public final class HistoryStore {
    public let paths: TackPaths
    private let db: Database
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(paths: TackPaths) throws {
        self.paths = paths
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        db = try Database(path: paths.database.path)
        try db.execute("PRAGMA journal_mode=WAL")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS items (
                id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                dedupe_key TEXT,
                json BLOB NOT NULL
            )
            """)
        try db.execute("CREATE INDEX IF NOT EXISTS items_created_at ON items(created_at)")
        try db.execute("CREATE INDEX IF NOT EXISTS items_dedupe_key ON items(dedupe_key)")
    }

    public func load() -> [HistoryItem] {
        db.query("SELECT json FROM items ORDER BY created_at DESC") { try? decoder.decode(HistoryItem.self, from: $0.data(0)) }
    }

    @discardableResult
    public func add(_ item: HistoryItem, dedupe: Bool) -> HistoryItem {
        let key = dedupeKey(for: item)
        if dedupe, let key,
           var existing = db.query("SELECT json FROM items WHERE dedupe_key = ? AND id != ? ORDER BY created_at DESC LIMIT 1", [.text(key), .text(item.id.uuidString)], { try? decoder.decode(HistoryItem.self, from: $0.data(0)) }).first {
            existing.createdAt = item.createdAt
            existing.sourceApp = item.sourceApp
            write(existing, key: key)
            let kept = Set(existing.imagePaths)
            for path in item.imagePaths where !kept.contains(path) && isInside(path, paths.clips) {
                try? FileManager.default.removeItem(atPath: path)
            }
            return existing
        }
        write(item, key: key)
        return item
    }

    public func update(_ item: HistoryItem) {
        write(item, key: dedupeKey(for: item))
    }

    public func delete(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        let all = load()
        let removed = all.filter { idSet.contains($0.id) }
        let remaining = all.filter { !idSet.contains($0.id) }
        try? db.execute("BEGIN")
        for id in ids {
            db.run("DELETE FROM items WHERE id = ?", [.text(id.uuidString)])
        }
        try? db.execute("COMMIT")

        let stillReferenced = Set(remaining.flatMap(\.imagePaths))
        let stillOwnedDirs = Set(remaining.compactMap(\.sessionDir))
        let fm = FileManager.default
        for item in removed {
            if item.kind == .image {
                for path in item.imagePaths where isInside(path, paths.clips) && !stillReferenced.contains(path) {
                    try? fm.removeItem(atPath: path)
                }
            }
            if let dir = item.sessionDir, isInside(dir, paths.sessions), !stillOwnedDirs.contains(dir) {
                try? fm.removeItem(atPath: dir)
            }
        }
    }

    public func prune(keepingNewest limit: Int) {
        let ids = db.query("SELECT id FROM items ORDER BY created_at DESC LIMIT -1 OFFSET ?", [.int(max(0, limit))]) { UUID(uuidString: $0.text(0)) }
        delete(ids: ids)
    }

    public func deleteAll() {
        delete(ids: db.query("SELECT id FROM items") { UUID(uuidString: $0.text(0)) })
    }

    private func write(_ item: HistoryItem, key: String?) {
        guard let json = try? encoder.encode(item) else { return }
        db.run(
            "INSERT OR REPLACE INTO items (id, created_at, dedupe_key, json) VALUES (?, ?, ?, ?)",
            [.text(item.id.uuidString), .double(item.createdAt.timeIntervalSinceReferenceDate), key.map(Database.Value.text) ?? .null, .blob(json)]
        )
    }

    private func dedupeKey(for item: HistoryItem) -> String? {
        switch item.kind {
        case .text:
            return "text:" + sha256(Data(item.text.utf8))
        case .image:
            guard let path = item.imagePaths.first, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            return "image:" + sha256(data)
        case .file:
            return "file:" + sha256(Data(item.filePaths.joined(separator: "\n").utf8))
        case .session:
            return nil
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func isInside(_ path: String, _ dir: URL) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path + "/")
    }
}

private final class Database {
    enum Value {
        case text(String)
        case int(Int)
        case double(Double)
        case blob(Data)
        case null
    }

    struct Row {
        let statement: OpaquePointer

        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }

        func data(_ column: Int32) -> Data {
            guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }

    struct SQLiteError: LocalizedError {
        let message: String
        var errorDescription: String? { "SQLite: \(message)" }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var handle: OpaquePointer?

    init(path: String) throws {
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(handle)
            throw SQLiteError(message: message)
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        if sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    func run(_ sql: String, _ values: [Value] = []) {
        _ = query(sql, values) { _ in () }
    }

    func query<T>(_ sql: String, _ values: [Value] = [], _ map: (Row) -> T?) -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .int(let int): sqlite3_bind_int64(statement, index, Int64(int))
            case .double(let double): sqlite3_bind_double(statement, index, double)
            case .blob(let data): _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient) }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        var results: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = map(Row(statement: statement)) { results.append(value) }
        }
        return results
    }
}
