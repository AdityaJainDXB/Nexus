import Foundation
import SQLite3

/// A value bound to / read from SQLite.
public enum SQLValue: Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public var string: String? { if case .text(let s) = self { return s }; return nil }
    public var int: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int64(d)
        case .text(let s): return Int64(s)
        default: return nil
        }
    }
    public var double: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    public var data: Data? { if case .blob(let d) = self { return d }; return nil }
}

public protocol SQLConvertible { var sqlValue: SQLValue { get } }
extension String: SQLConvertible { public var sqlValue: SQLValue { .text(self) } }
extension Int: SQLConvertible { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLConvertible { public var sqlValue: SQLValue { .int(self) } }
extension Double: SQLConvertible { public var sqlValue: SQLValue { .double(self) } }
extension Bool: SQLConvertible { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Data: SQLConvertible { public var sqlValue: SQLValue { .blob(self) } }
extension Date: SQLConvertible { public var sqlValue: SQLValue { .double(timeIntervalSince1970) } }
extension Optional: SQLConvertible where Wrapped: SQLConvertible {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

public struct SQLRow {
    public let values: [String: SQLValue]
    public subscript(_ key: String) -> SQLValue { values[key] ?? .null }
    public func string(_ k: String) -> String? { self[k].string }
    public func int(_ k: String) -> Int { Int(self[k].int ?? 0) }
    public func double(_ k: String) -> Double { self[k].double ?? 0 }
    public func data(_ k: String) -> Data? { self[k].data }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { "SQLite: \(message)" }
}

/// Minimal thread-safe SQLite wrapper (WAL mode, recursive lock so transactions can nest calls).
public final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            throw SQLiteError(message: "cannot open \(path)")
        }
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA synchronous=NORMAL")
    }

    deinit { sqlite3_close(handle) }

    private var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError(message: "\(errorMessage) — \(sql)")
        }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case .blob(let v):
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), Self.transient) }
            }
        }
        return stmt
    }

    @discardableResult
    public func execute(_ sql: String, _ params: [SQLConvertible] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params.map(\.sqlValue))
        defer { sqlite3_finalize(stmt) }
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW { rc = sqlite3_step(stmt) }
        guard rc == SQLITE_DONE else { throw SQLiteError(message: "\(errorMessage) — \(sql)") }
        return Int(sqlite3_changes(handle))
    }

    /// Executes multiple semicolon-separated statements (no parameters).
    public func executeScript(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw SQLiteError(message: msg)
        }
    }

    public func query(_ sql: String, _ params: [SQLConvertible] = []) throws -> [SQLRow] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params.map(\.sqlValue))
        defer { sqlite3_finalize(stmt) }
        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(message: "\(errorMessage) — \(sql)") }
            var dict: [String: SQLValue] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: dict[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: dict[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: dict[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    if let p = sqlite3_column_blob(stmt, c), n > 0 { dict[name] = .blob(Data(bytes: p, count: n)) } else { dict[name] = .blob(Data()) }
                default: dict[name] = .null
                }
            }
            rows.append(SQLRow(values: dict))
        }
        return rows
    }

    public func scalarInt(_ sql: String, _ params: [SQLConvertible] = []) -> Int {
        guard let row = try? query(sql, params).first, let v = row.values.values.first else { return 0 }
        return Int(v.int ?? 0)
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try execute("COMMIT")
            return r
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
