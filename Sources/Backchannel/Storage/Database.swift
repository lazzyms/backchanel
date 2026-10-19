import Foundation
import SQLite3

/// Thin SQLite wrapper over the system library. One connection, serialized on an actor.
actor Database {
    private nonisolated(unsafe) var db: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw DatabaseError.open(url.path) }
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;" + Schema.sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DatabaseError.sql(msg)
        }
        // Columns added after the first release. SQLite has no ADD COLUMN IF NOT EXISTS; a duplicate is harmless.
        for migration in Schema.migrations { sqlite3_exec(db, migration, nil, nil, nil) }
    }

    isolated deinit { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DatabaseError.sql(msg)
        }
    }

    enum Value { case int(Int64), double(Double), text(String), blob(Data), null }

    @discardableResult
    func run(_ sql: String, _ args: [Value] = []) throws -> Int64 {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.sql(String(cString: sqlite3_errmsg(db))) }
        return sqlite3_last_insert_rowid(db)
    }

    func query<T>(_ sql: String, _ args: [Value] = [], _ map: (Row) throws -> T) throws -> [T] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { out.append(try map(Row(stmt: stmt))) }
            else if rc == SQLITE_DONE { break }
            else { throw DatabaseError.sql(String(cString: sqlite3_errmsg(db))) }
        }
        return out
    }

    private func prepare(_ sql: String, _ args: [Value]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.sql(String(cString: sqlite3_errmsg(db)))
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, transient)
            case .blob(let v): v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), transient) }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    struct Row {
        let stmt: OpaquePointer
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        func optionalText(_ i: Int32) -> String? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : text(i) }
        func blob(_ i: Int32) -> Data {
            guard let p = sqlite3_column_blob(stmt, i) else { return Data() }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
        }
    }
}

enum DatabaseError: Error, LocalizedError {
    case open(String), sql(String)
    var errorDescription: String? {
        switch self {
        case .open(let p): "Could not open database at \(p)"
        case .sql(let m): "SQLite: \(m)"
        }
    }
}

enum Schema {
    static let migrations = [
        "ALTER TABLE meetings ADD COLUMN summary TEXT",
        "ALTER TABLE segments ADD COLUMN speaker_name TEXT",
    ]
    static let sql = """
    CREATE TABLE IF NOT EXISTS sources (
        id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, title TEXT NOT NULL, kind TEXT NOT NULL,
        text TEXT NOT NULL, embedding BLOB, label TEXT, label_rationale TEXT,
        proj_x REAL, proj_y REAL, created_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS chunks (
        id INTEGER PRIMARY KEY, source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
        idx INTEGER NOT NULL, text TEXT NOT NULL, embedding BLOB NOT NULL
    );
    CREATE INDEX IF NOT EXISTS chunks_source ON chunks(source_id);
    CREATE TABLE IF NOT EXISTS meetings (
        id INTEGER PRIMARY KEY, title TEXT NOT NULL, started_at REAL NOT NULL, ended_at REAL
    );
    CREATE TABLE IF NOT EXISTS segments (
        id INTEGER PRIMARY KEY, meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        speaker TEXT NOT NULL, text TEXT NOT NULL, start_sec REAL NOT NULL, end_sec REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS segments_meeting ON segments(meeting_id);
    CREATE TABLE IF NOT EXISTS meeting_chunks (
        id INTEGER PRIMARY KEY, meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        idx INTEGER NOT NULL, text TEXT NOT NULL, embedding BLOB
    );
    CREATE INDEX IF NOT EXISTS meeting_chunks_meeting ON meeting_chunks(meeting_id);
    CREATE TABLE IF NOT EXISTS speakers (
        id INTEGER PRIMARY KEY, name TEXT NOT NULL, embedding BLOB NOT NULL
    );
    CREATE TABLE IF NOT EXISTS insights (
        id INTEGER PRIMARY KEY, meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        question TEXT NOT NULL, answer TEXT NOT NULL, source_titles TEXT NOT NULL, created_at REAL NOT NULL
    );
    """
}

/// Float vectors are stored as little-endian Float32 blobs.
extension Data {
    init(vector: [Float]) { self = vector.withUnsafeBufferPointer { Data(buffer: $0) } }
    var floatVector: [Float] {
        var out = [Float](repeating: 0, count: count / MemoryLayout<Float>.size)
        _ = out.withUnsafeMutableBytes { copyBytes(to: $0) }
        return out
    }
}

enum Vectors {
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let d = (na.squareRoot() * nb.squareRoot())
        return d == 0 ? 0 : dot / d
    }
    static func normalized(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n == 0 ? v : v.map { $0 / n }
    }
    static func mean(_ vs: [[Float]]) -> [Float] {
        guard let first = vs.first else { return [] }
        var acc = [Float](repeating: 0, count: first.count)
        for v in vs { for i in 0..<acc.count { acc[i] += v[i] } }
        return normalized(acc.map { $0 / Float(vs.count) })
    }
}
