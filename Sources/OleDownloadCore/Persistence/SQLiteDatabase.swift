import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin wrapper around the SQLite C API. Not thread-safe by itself:
/// `DownloadRepository` confines every call to one serial queue.
// @unchecked: the connection is opened with SQLITE_OPEN_NOMUTEX and every use is confined to
// DownloadRepository's serial queue (or a single test), which provides the required exclusion.
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?

    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLiteError(code: SQLITE_CANTOPEN, message: msg)
        }
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA foreign_keys = ON;")
    }

    /// In-memory database for tests.
    public static func inMemory() throws -> SQLiteDatabase { try SQLiteDatabase(path: ":memory:") }

    deinit { sqlite3_close_v2(handle) }

    private var lastError: SQLiteError {
        SQLiteError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }

    public func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw SQLiteError(code: sqlite3_errcode(handle), message: message)
        }
    }

    public func run(_ sql: String, _ params: [SQLValue] = []) throws {
        let stmt = try prepare(sql)
        try stmt.bind(params)
        _ = try stmt.step()
    }

    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [Row] {
        let stmt = try prepare(sql)
        try stmt.bind(params)
        var rows: [Row] = []
        while try stmt.step() { rows.append(stmt.row()) }
        return rows
    }

    public func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw lastError }
        return Statement(stmt: stmt, db: self)
    }

    /// Runs `body` in a transaction; rolls back if it throws.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public var userVersion: Int {
        get { (try? query("PRAGMA user_version;").first?.int(0)).flatMap { $0 }.map(Int.init) ?? 0 }
    }

    public func setUserVersion(_ v: Int) throws { try execute("PRAGMA user_version = \(v);") }

    public func tableExists(_ name: String) throws -> Bool {
        try !query("SELECT name FROM sqlite_master WHERE type='table' AND name=?;", [.text(name)]).isEmpty
    }

    public func columns(of table: String) throws -> [String] {
        try query("PRAGMA table_info(\(table));").compactMap { $0.text(1) }
    }

    public final class Statement {
        let stmt: OpaquePointer
        unowned let db: SQLiteDatabase

        init(stmt: OpaquePointer, db: SQLiteDatabase) {
            self.stmt = stmt
            self.db = db
        }

        deinit { sqlite3_finalize(stmt) }

        public func bind(_ params: [SQLValue]) throws {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            for (i, value) in params.enumerated() {
                let idx = Int32(i + 1)
                let rc: Int32
                switch value {
                case .null: rc = sqlite3_bind_null(stmt, idx)
                case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
                case .double(let v): rc = sqlite3_bind_double(stmt, idx, v)
                case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
                case .blob(let v):
                    rc = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
                }
                guard rc == SQLITE_OK else { throw db.lastError }
            }
        }

        /// Returns true when a row is available.
        public func step() throws -> Bool {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw db.lastError
            }
        }

        func row() -> Row {
            let count = sqlite3_column_count(stmt)
            var values: [SQLValue] = []
            values.reserveCapacity(Int(count))
            for i in 0..<count {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: values.append(.int(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT: values.append(.double(sqlite3_column_double(stmt, i)))
                case SQLITE_TEXT: values.append(.text(String(cString: sqlite3_column_text(stmt, i))))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, i))
                    if let p = sqlite3_column_blob(stmt, i), n > 0 { values.append(.blob(Data(bytes: p, count: n))) } else { values.append(.blob(Data())) }
                default: values.append(.null)
                }
            }
            return Row(values: values)
        }
    }

    public struct Row: Sendable {
        public let values: [SQLValue]
        public func int(_ i: Int) -> Int64? { if case .int(let v) = values[i] { return v }; if case .double(let d) = values[i] { return Int64(d) }; return nil }
        public func double(_ i: Int) -> Double? { if case .double(let v) = values[i] { return v }; if case .int(let v) = values[i] { return Double(v) }; return nil }
        public func text(_ i: Int) -> String? { if case .text(let v) = values[i] { return v }; return nil }
        public func blob(_ i: Int) -> Data? { if case .blob(let v) = values[i] { return v }; return nil }
        public func bool(_ i: Int) -> Bool? { int(i).map { $0 != 0 } }
    }
}

extension SQLValue {
    static func from(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
    static func from(_ i: Int64?) -> SQLValue { i.map { .int($0) } ?? .null }
    static func from(_ i: Int?) -> SQLValue { i.map { .int(Int64($0)) } ?? .null }
    static func from(_ d: Double?) -> SQLValue { d.map { .double($0) } ?? .null }
    /// Dates are stored as Unix epoch seconds (UTC, REAL).
    static func from(_ d: Date?) -> SQLValue { d.map { .double($0.timeIntervalSince1970) } ?? .null }
    static func from(_ b: Bool?) -> SQLValue { b.map { .int($0 ? 1 : 0) } ?? .null }
    static func from(_ d: Data?) -> SQLValue { d.map { .blob($0) } ?? .null }
}
