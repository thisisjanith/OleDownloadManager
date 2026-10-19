import Foundation

public struct DiagnosticEvent: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var downloadID: UUID?
    public var at: Date
    public var level: String
    public var message: String
}

/// Storage abstraction so the coordinator can be tested against any backend.
public protocol DownloadStore: AnyObject, Sendable {
    func loadAll() throws -> [DownloadRecord]
    func save(_ record: DownloadRecord)
    func saveProgress(id: UUID, bytesReceived: Int64, segments: [DownloadSegment])
    func saveQueueOrder(_ order: [(UUID, Int)])
    func delete(ids: [UUID])
    func loadSettings() -> AppSettings?
    func saveSettings(_ settings: AppSettings)
    func loadValue(_ key: String) -> String?
    func saveValue(_ key: String, _ value: String)
    func logEvent(downloadID: UUID?, level: String, message: String)
    func events(for downloadID: UUID, limit: Int) -> [DiagnosticEvent]
    /// Blocks until every queued write has been committed.
    func flush()
}

/// SQLite-backed store. All database access happens on one serial queue, so writes are applied
/// in the order they were issued and never block the main thread (except `flush` and reads).
public final class DownloadRepository: DownloadStore, @unchecked Sendable {
    private let db: SQLiteDatabase
    private let queue = DispatchQueue(label: "com.oledownloadmanager.database", qos: .utility)
    private let logger = AppLog.persistence
    private static let maxDiagnosticEvents = 5000

    public init(database: SQLiteDatabase) throws {
        self.db = database
        try queue.sync { _ = try DatabaseMigrations.migrate(database) }
    }

    /// Opens (creating if needed) the database in `directory`.
    public convenience init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: directory.appendingPathComponent("OleDownloadManager.sqlite").path)
        try self.init(database: db)
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("OleDownloadManager", isDirectory: true)
    }

    // MARK: Downloads

    public func loadAll() throws -> [DownloadRecord] {
        try queue.sync {
            let rows = try db.query("SELECT \(Self.columns) FROM downloads ORDER BY queue_position, created_at;")
            var segmentsByID: [String: [DownloadSegment]] = [:]
            for r in try db.query("SELECT download_id, segment_index, range_start, range_end, completed FROM download_segments ORDER BY download_id, segment_index;") {
                guard let id = r.text(0) else { continue }
                segmentsByID[id, default: []].append(DownloadSegment(
                    index: Int(r.int(1) ?? 0), start: r.int(2) ?? 0, end: r.int(3) ?? 0, completed: r.int(4) ?? 0))
            }
            return rows.compactMap { row in
                guard var rec = Self.decode(row) else { return nil }
                rec.segments = segmentsByID[rec.id.uuidString] ?? []
                return rec
            }
        }
    }

    public func save(_ record: DownloadRecord) {
        queue.async { [db, logger] in
            do {
                try db.transaction {
                    try db.run("INSERT OR REPLACE INTO downloads (\(Self.columns)) VALUES (\(Self.placeholders));", Self.encode(record))
                    try Self.writeSegments(db, id: record.id, segments: record.segments)
                }
            } catch {
                logger.error("save failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    public func saveProgress(id: UUID, bytesReceived: Int64, segments: [DownloadSegment]) {
        queue.async { [db, logger] in
            do {
                try db.transaction {
                    try db.run("UPDATE downloads SET bytes_received = ? WHERE id = ?;", [.int(bytesReceived), .text(id.uuidString)])
                    try Self.writeSegments(db, id: id, segments: segments)
                }
            } catch {
                logger.error("progress save failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    public func saveQueueOrder(_ order: [(UUID, Int)]) {
        queue.async { [db, logger] in
            do {
                try db.transaction {
                    for (id, pos) in order {
                        try db.run("UPDATE downloads SET queue_position = ? WHERE id = ?;", [.int(Int64(pos)), .text(id.uuidString)])
                    }
                }
            } catch {
                logger.error("queue order save failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    public func delete(ids: [UUID]) {
        queue.async { [db, logger] in
            do {
                try db.transaction {
                    for id in ids {
                        try db.run("DELETE FROM downloads WHERE id = ?;", [.text(id.uuidString)])
                        try db.run("DELETE FROM diagnostic_events WHERE download_id = ?;", [.text(id.uuidString)])
                    }
                }
            } catch {
                logger.error("delete failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static func writeSegments(_ db: SQLiteDatabase, id: UUID, segments: [DownloadSegment]) throws {
        try db.run("DELETE FROM download_segments WHERE download_id = ?;", [.text(id.uuidString)])
        guard !segments.isEmpty else { return }
        let stmt = try db.prepare("INSERT INTO download_segments (download_id, segment_index, range_start, range_end, completed) VALUES (?, ?, ?, ?, ?);")
        for s in segments {
            try stmt.bind([.text(id.uuidString), .int(Int64(s.index)), .int(s.start), .int(s.end), .int(s.completed)])
            _ = try stmt.step()
        }
    }

    // MARK: Settings

    public func loadSettings() -> AppSettings? {
        guard let json = loadValue("app.settings"), let data = json.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(AppSettings.self, from: data))?.validated()
    }

    public func saveSettings(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings.validated()), let json = String(data: data, encoding: .utf8) else { return }
        saveValue("app.settings", json)
    }

    public func loadValue(_ key: String) -> String? {
        queue.sync { try? db.query("SELECT value FROM settings WHERE key = ?;", [.text(key)]).first?.text(0) }
    }

    public func saveValue(_ key: String, _ value: String) {
        queue.async { [db] in
            try? db.run("INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?);",
                        [.text(key), .text(value), .double(Date().timeIntervalSince1970)])
        }
    }

    // MARK: Diagnostics

    public func logEvent(downloadID: UUID?, level: String, message: String) {
        queue.async { [db] in
            try? db.run("INSERT INTO diagnostic_events (download_id, at, level, message) VALUES (?, ?, ?, ?);",
                        [.from(downloadID?.uuidString), .double(Date().timeIntervalSince1970), .text(level), .text(String(message.prefix(2000)))])
            // Keep the table bounded.
            try? db.run("DELETE FROM diagnostic_events WHERE id <= (SELECT MAX(id) FROM diagnostic_events) - ?;", [.int(Int64(Self.maxDiagnosticEvents))])
        }
    }

    public func events(for downloadID: UUID, limit: Int = 50) -> [DiagnosticEvent] {
        queue.sync {
            let rows = (try? db.query("SELECT id, download_id, at, level, message FROM diagnostic_events WHERE download_id = ? ORDER BY id DESC LIMIT ?;",
                                      [.text(downloadID.uuidString), .int(Int64(limit))])) ?? []
            return rows.map { r in
                DiagnosticEvent(id: r.int(0) ?? 0, downloadID: r.text(1).flatMap(UUID.init(uuidString:)),
                                at: Date(timeIntervalSince1970: r.double(2) ?? 0), level: r.text(3) ?? "info", message: r.text(4) ?? "")
            }
        }
    }

    public func flush() { queue.sync {} }

    // MARK: Row mapping

    static let columnList = [
        "id", "source_url", "final_url", "file_name", "file_name_user_provided", "destination_dir", "destination_volume_uuid",
        "final_path", "partial_path", "category", "state", "expected_length", "bytes_received", "created_at", "started_at",
        "completed_at", "retry_count", "http_status", "etag", "last_modified", "content_type", "supports_ranges", "last_error",
        "sha256", "origin", "page_url", "referrer", "custom_headers", "has_stored_secrets", "conflict_policy", "max_connections",
        "start_mode", "queue_position", "scheduled_at", "average_speed", "trashed_at", "expected_sha256", "checksum_verified",
        "speed_limit",
    ]
    static let columns = columnList.joined(separator: ", ")
    static let placeholders = Array(repeating: "?", count: columnList.count).joined(separator: ", ")

    static func encode(_ r: DownloadRecord) -> [SQLValue] {
        let errorJSON = r.lastError.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        let headersJSON = r.customHeaders.isEmpty ? nil : (try? JSONEncoder().encode(r.customHeaders.filter { !Redactor.isSensitiveHeader($0.key) }))
            .flatMap { String(data: $0, encoding: .utf8) }
        return [
            .text(r.id.uuidString), .text(r.sourceURL.absoluteString), .from(r.finalURL?.absoluteString), .text(r.fileName),
            .from(r.fileNameIsUserProvided), .text(r.destinationDirectory.path), .from(r.destinationVolumeUUID),
            .from(r.finalFileURL?.path), .from(r.partialFileURL?.path), .text(r.categoryID), .text(r.state.rawValue),
            .from(r.expectedLength), .int(r.bytesReceived), .from(r.createdAt), .from(r.startedAt), .from(r.completedAt),
            .int(Int64(r.retryCount)), .from(r.httpStatus), .from(r.validators.etag), .from(r.validators.lastModified),
            .from(r.contentType), .from(r.supportsRanges), .from(errorJSON), .from(r.sha256), .text(r.origin.rawValue),
            .from(r.pageURL), .from(r.referrer), .from(headersJSON), .from(r.hasStoredSecrets), .from(r.conflictPolicy?.rawValue),
            .from(r.maxConnections), .text(r.startMode.rawValue), .int(Int64(r.queuePosition)), .from(r.scheduledAt),
            .from(r.averageSpeed), .from(r.trashedAt), .from(r.expectedSHA256), .from(r.checksumVerified), .from(r.speedLimit),
        ]
    }

    static func decode(_ row: SQLiteDatabase.Row) -> DownloadRecord? {
        func date(_ i: Int) -> Date? { row.double(i).map { Date(timeIntervalSince1970: $0) } }
        guard let idString = row.text(0), let id = UUID(uuidString: idString),
              let source = row.text(1).flatMap(URL.init(string:)),
              let fileName = row.text(3), let dir = row.text(5),
              let category = row.text(9), let state = row.text(10).flatMap(DownloadState.init(rawValue:)),
              let created = date(13) else { return nil }
        var r = DownloadRecord(id: id, sourceURL: source, fileName: fileName,
                               destinationDirectory: URL(fileURLWithPath: dir, isDirectory: true),
                               categoryID: category, state: state, createdAt: created)
        r.finalURL = row.text(2).flatMap(URL.init(string:))
        r.fileNameIsUserProvided = row.bool(4) ?? false
        r.destinationVolumeUUID = row.text(6)
        r.finalFileURL = row.text(7).map { URL(fileURLWithPath: $0) }
        r.partialFileURL = row.text(8).map { URL(fileURLWithPath: $0) }
        r.expectedLength = row.int(11)
        r.bytesReceived = row.int(12) ?? 0
        r.startedAt = date(14)
        r.completedAt = date(15)
        r.retryCount = Int(row.int(16) ?? 0)
        r.httpStatus = row.int(17).map(Int.init)
        r.validators = ResourceValidators(etag: row.text(18), lastModified: row.text(19), contentLength: r.expectedLength)
        r.contentType = row.text(20)
        r.supportsRanges = row.bool(21)
        r.lastError = row.text(22).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(DownloadError.self, from: $0) }
        r.sha256 = row.text(23)
        r.origin = row.text(24).flatMap(DownloadOrigin.init(rawValue:)) ?? .user
        r.pageURL = row.text(25)
        r.referrer = row.text(26)
        r.customHeaders = row.text(27).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        r.hasStoredSecrets = row.bool(28) ?? false
        r.conflictPolicy = row.text(29).flatMap(ConflictPolicy.init(rawValue:))
        r.maxConnections = row.int(30).map(Int.init)
        r.startMode = row.text(31).flatMap(StartMode.init(rawValue:)) ?? .queue
        r.queuePosition = Int(row.int(32) ?? 0)
        r.scheduledAt = date(33)
        r.averageSpeed = row.double(34)
        r.trashedAt = date(35)
        r.expectedSHA256 = row.text(36)
        r.checksumVerified = row.bool(37)
        r.speedLimit = row.int(38)
        return r
    }
}
