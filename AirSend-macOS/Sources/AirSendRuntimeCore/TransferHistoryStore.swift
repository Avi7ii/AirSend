import Foundation
import SQLite3

public enum TransferHistoryError: Error, Sendable {
    case openFailed(String)
    case sqlite(code: Int32, message: String)
    case nonTerminalRecord(UUID)
    case invalidRecordData
}

public actor TransferHistoryStore {
    public static let schemaVersion = 1

    public let fileURL: URL
    private let database: SQLiteDatabaseHandle
    private var retentionLimitPerDirection: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL, retentionLimitPerDirection: Int = 30) throws {
        self.fileURL = fileURL
        self.retentionLimitPerDirection = max(1, retentionLimitPerDirection)

        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            fileURL.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            sqlite3_close(handle)
            throw TransferHistoryError.openFailed(message)
        }
        do {
            try Self.execute(handle, sql: "PRAGMA journal_mode=WAL;")
            try Self.execute(handle, sql: "PRAGMA synchronous=FULL;")
            try Self.execute(handle, sql: "PRAGMA foreign_keys=ON;")
            try Self.execute(handle, sql: "PRAGMA busy_timeout=5000;")
            try Self.execute(
                handle,
                sql:
                """
                CREATE TABLE IF NOT EXISTS transfer_history (
                    id TEXT PRIMARY KEY NOT NULL,
                    direction TEXT NOT NULL,
                    status TEXT NOT NULL,
                    started_at REAL NOT NULL,
                    ended_at REAL NOT NULL,
                    record_json BLOB NOT NULL
                );
                CREATE INDEX IF NOT EXISTS transfer_history_started_idx
                    ON transfer_history(started_at DESC);
                """
            )
            try Self.execute(handle, sql: "PRAGMA user_version=\(Self.schemaVersion);")
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            sqlite3_close(handle)
            throw error
        }
        self.database = SQLiteDatabaseHandle(handle)
    }

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AirSend-macOS", isDirectory: true)
            .appendingPathComponent("transfer-history.sqlite3", isDirectory: false)
    }

    public func setRetentionLimitPerDirection(_ limit: Int) throws {
        retentionLimitPerDirection = max(1, limit)
        try prune()
    }

    public func persist(_ record: TransferRecord) throws {
        guard record.status.isTerminal, record.endedAt != nil else {
            throw TransferHistoryError.nonTerminalRecord(record.id)
        }
        let data = try encoder.encode(record)
        let sql = """
            INSERT INTO transfer_history (id, direction, status, started_at, ended_at, record_json)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                direction=excluded.direction,
                status=excluded.status,
                started_at=excluded.started_at,
                ended_at=excluded.ended_at,
                record_json=excluded.record_json;
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(record.id.uuidString, index: 1, statement: statement)
        try bindText(record.direction.rawValue, index: 2, statement: statement)
        try bindText(record.status.rawValue, index: 3, statement: statement)
        sqlite3_bind_double(statement, 4, record.startedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 5, record.endedAt!.timeIntervalSince1970)
        let bindResult = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 6, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
        try check(bindResult)
        try stepDone(statement)
        try prune(direction: record.direction)
    }

    public func list(limit: Int = 100, direction: TransferDirection? = nil) throws -> [TransferRecord] {
        try prune()
        let boundedLimit = max(1, min(limit, 1_000))
        let sql: String
        if direction == nil {
            sql = "SELECT record_json FROM transfer_history ORDER BY started_at DESC LIMIT ?;"
        } else {
            sql = "SELECT record_json FROM transfer_history WHERE direction=? ORDER BY started_at DESC LIMIT ?;"
        }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var limitIndex: Int32 = 1
        if let direction {
            try bindText(direction.rawValue, index: 1, statement: statement)
            limitIndex = 2
        }
        try check(sqlite3_bind_int(statement, limitIndex, Int32(boundedLimit)))

        var records: [TransferRecord] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw sqliteError(code: result) }
            guard let bytes = sqlite3_column_blob(statement, 0) else {
                throw TransferHistoryError.invalidRecordData
            }
            let count = Int(sqlite3_column_bytes(statement, 0))
            let data = Data(bytes: bytes, count: count)
            records.append(try decoder.decode(TransferRecord.self, from: data))
        }
        return records
    }

    public func delete(id: UUID) throws {
        let statement = try prepare("DELETE FROM transfer_history WHERE id=?;")
        defer { sqlite3_finalize(statement) }
        try bindText(id.uuidString, index: 1, statement: statement)
        try stepDone(statement)
    }

    public func clear(direction: TransferDirection? = nil) throws {
        if let direction {
            let statement = try prepare("DELETE FROM transfer_history WHERE direction=?;")
            defer { sqlite3_finalize(statement) }
            try bindText(direction.rawValue, index: 1, statement: statement)
            try stepDone(statement)
        } else {
            try execute("DELETE FROM transfer_history;")
        }
    }

    public func count(direction: TransferDirection? = nil) throws -> Int {
        let sql = direction == nil
            ? "SELECT COUNT(*) FROM transfer_history;"
            : "SELECT COUNT(*) FROM transfer_history WHERE direction=?;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        if let direction {
            try bindText(direction.rawValue, index: 1, statement: statement)
        }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else { throw sqliteError(code: result) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func prune() throws {
        try prune(direction: .outgoing)
        try prune(direction: .incoming)
    }

    private func prune(direction: TransferDirection) throws {
        let statement = try prepare(
            """
            DELETE FROM transfer_history
            WHERE direction=? AND id NOT IN (
                SELECT id FROM transfer_history
                WHERE direction=?
                ORDER BY started_at DESC
                LIMIT ?
            );
            """
        )
        defer { sqlite3_finalize(statement) }
        try bindText(direction.rawValue, index: 1, statement: statement)
        try bindText(direction.rawValue, index: 2, statement: statement)
        try check(sqlite3_bind_int(statement, 3, Int32(retentionLimitPerDirection)))
        try stepDone(statement)
    }

    private func execute(_ sql: String) throws {
        try Self.execute(database.pointer, sql: sql)
    }

    private static func execute(_ database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw TransferHistoryError.sqlite(code: result, message: message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        let database = database.pointer
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw sqliteError(code: result) }
        return statement
    }

    private func bindText(_ value: String, index: Int32, statement: OpaquePointer) throws {
        try check(sqlite3_bind_text(statement, index, value, -1, sqliteTransient))
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw sqliteError(code: result) }
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK else { throw sqliteError(code: result) }
    }

    private func sqliteError(code: Int32) -> TransferHistoryError {
        let message = String(cString: sqlite3_errmsg(database.pointer))
        return .sqlite(code: code, message: message)
    }
}

private final class SQLiteDatabaseHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close(pointer)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
