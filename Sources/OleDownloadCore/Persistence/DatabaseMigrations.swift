import Foundation

/// Ordered schema migrations. Each runs once inside a transaction and bumps `PRAGMA user_version`.
/// Never edit a shipped migration; append a new one instead.
public enum DatabaseMigrations {
    public struct Migration: Sendable {
        public let version: Int
        public let name: String
        public let sql: String
    }

    public static let all: [Migration] = [
        Migration(version: 1, name: "initial schema", sql: """
            CREATE TABLE downloads (
                id TEXT PRIMARY KEY NOT NULL,
                source_url TEXT NOT NULL,
                final_url TEXT,
                file_name TEXT NOT NULL,
                file_name_user_provided INTEGER NOT NULL DEFAULT 0,
                destination_dir TEXT NOT NULL,
                destination_volume_uuid TEXT,
                final_path TEXT,
                partial_path TEXT,
                category TEXT NOT NULL,
                state TEXT NOT NULL,
                expected_length INTEGER,
                bytes_received INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                started_at REAL,
                completed_at REAL,
                retry_count INTEGER NOT NULL DEFAULT 0,
                http_status INTEGER,
                etag TEXT,
                last_modified TEXT,
                content_type TEXT,
                supports_ranges INTEGER,
                last_error TEXT,
                sha256 TEXT,
                origin TEXT NOT NULL DEFAULT 'user',
                page_url TEXT,
                referrer TEXT,
                custom_headers TEXT,
                has_stored_secrets INTEGER NOT NULL DEFAULT 0,
                conflict_policy TEXT,
                max_connections INTEGER,
                start_mode TEXT NOT NULL DEFAULT 'queue',
                queue_position INTEGER NOT NULL DEFAULT 0,
                scheduled_at REAL,
                average_speed REAL,
                trashed_at REAL
            );
            CREATE INDEX downloads_state ON downloads(state);
            CREATE INDEX downloads_queue ON downloads(queue_position);
            CREATE TABLE download_segments (
                download_id TEXT NOT NULL REFERENCES downloads(id) ON DELETE CASCADE,
                segment_index INTEGER NOT NULL,
                range_start INTEGER NOT NULL,
                range_end INTEGER NOT NULL,
                completed INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (download_id, segment_index)
            );
            CREATE TABLE settings (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL,
                updated_at REAL NOT NULL
            );
            """),
        Migration(version: 2, name: "integrity and diagnostics", sql: """
            ALTER TABLE downloads ADD COLUMN expected_sha256 TEXT;
            ALTER TABLE downloads ADD COLUMN checksum_verified INTEGER;
            ALTER TABLE downloads ADD COLUMN speed_limit INTEGER;
            CREATE TABLE diagnostic_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                download_id TEXT,
                at REAL NOT NULL,
                level TEXT NOT NULL,
                message TEXT NOT NULL
            );
            CREATE INDEX diagnostic_events_download ON diagnostic_events(download_id, at);
            """),
    ]

    public static var latestVersion: Int { all.last?.version ?? 0 }

    /// Applies every migration newer than the database's current version.
    /// - Parameter upTo: stop after this version (tests use it to build an old schema).
    @discardableResult
    public static func migrate(_ db: SQLiteDatabase, upTo: Int = Int.max) throws -> [Int] {
        var applied: [Int] = []
        let current = db.userVersion
        guard current <= latestVersion else {
            throw SQLiteError(code: -1, message: "Database schema version \(current) is newer than this app supports (\(latestVersion)). Update OleDownloadManager.")
        }
        for migration in all where migration.version > current && migration.version <= upTo {
            try db.transaction {
                try db.execute(migration.sql)
                try db.setUserVersion(migration.version)
            }
            applied.append(migration.version)
        }
        return applied
    }
}
