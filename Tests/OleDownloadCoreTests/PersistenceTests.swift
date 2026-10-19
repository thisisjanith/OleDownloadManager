import Foundation
import Testing
@testable import OleDownloadCore

@Suite("Persistence")
struct PersistenceTests {
    func sampleRecord(_ name: String = "a.zip", state: DownloadState = .queued, position: Int = 0) -> DownloadRecord {
        var r = DownloadRecord(sourceURL: URL(string: "https://example.com/\(name)")!, fileName: name,
                               destinationDirectory: URL(fileURLWithPath: "/tmp/dl", isDirectory: true), categoryID: "archives", state: state)
        r.queuePosition = position
        return r
    }

    @Test func freshMigrationCreatesLatestSchema() throws {
        let db = try SQLiteDatabase.inMemory()
        let applied = try DatabaseMigrations.migrate(db)
        #expect(applied == DatabaseMigrations.all.map(\.version))
        #expect(db.userVersion == DatabaseMigrations.latestVersion)
        #expect(try db.tableExists("downloads"))
        #expect(try db.tableExists("download_segments"))
        #expect(try db.tableExists("settings"))
        #expect(try db.tableExists("diagnostic_events"))
        #expect(try DatabaseMigrations.migrate(db).isEmpty)   // idempotent
    }

    @Test func upgradeFromVersion1KeepsData() throws {
        let db = try SQLiteDatabase.inMemory()
        try DatabaseMigrations.migrate(db, upTo: 1)
        #expect(db.userVersion == 1)
        try db.run("INSERT INTO downloads (id, source_url, file_name, destination_dir, category, state, created_at) VALUES ('11111111-1111-1111-1111-111111111111', 'https://e.com/x', 'x', '/tmp', 'other', 'paused', 0);")
        #expect(try !db.columns(of: "downloads").contains("expected_sha256"))
        let applied = try DatabaseMigrations.migrate(db)
        #expect(applied == [2])
        #expect(try db.columns(of: "downloads").contains("expected_sha256"))
        let repo = try DownloadRepository(database: db)
        let all = try repo.loadAll()
        #expect(all.count == 1)
        #expect(all.first?.state == .paused)
    }

    @Test func refusesNewerSchema() throws {
        let db = try SQLiteDatabase.inMemory()
        try db.setUserVersion(DatabaseMigrations.latestVersion + 1)
        #expect(throws: SQLiteError.self) { try DatabaseMigrations.migrate(db) }
    }

    @Test func failedMigrationRollsBack() throws {
        let db = try SQLiteDatabase.inMemory()
        #expect(throws: SQLiteError.self) {
            try db.transaction {
                try db.execute("CREATE TABLE t (x INTEGER);")
                try db.execute("THIS IS NOT SQL;")
            }
        }
        #expect(try !db.tableExists("t"))
    }

    @Test func roundTripsEveryField() throws {
        let repo = try DownloadRepository(database: .inMemory())
        var r = sampleRecord()
        r.createdAt = Date(timeIntervalSince1970: 1_790_000_000)
        r.finalURL = URL(string: "https://cdn.example.com/a.zip")
        r.fileNameIsUserProvided = true
        r.destinationVolumeUUID = "VOL"
        r.partialFileURL = URL(fileURLWithPath: "/tmp/dl/.part")
        r.finalFileURL = URL(fileURLWithPath: "/tmp/dl/a.zip")
        r.expectedLength = 1234
        r.bytesReceived = 600
        r.startedAt = Date(timeIntervalSince1970: 100)
        r.completedAt = Date(timeIntervalSince1970: 200)
        r.retryCount = 2
        r.httpStatus = 206
        r.validators = ResourceValidators(etag: "\"e\"", lastModified: "Mon", contentLength: 1234)
        r.contentType = "application/zip"
        r.supportsRanges = true
        r.segments = [DownloadSegment(index: 0, start: 0, end: 616, completed: 300), DownloadSegment(index: 1, start: 617, end: 1233, completed: 300)]
        r.lastError = DownloadError(.serverError, "boom", detail: "d", httpStatus: 503, retryAfter: 4)
        r.sha256 = "abc"
        r.expectedSHA256 = "def"
        r.checksumVerified = false
        r.origin = .browser
        r.pageURL = "https://example.com/page"
        r.referrer = "https://example.com/"
        r.customHeaders = ["Accept": "*/*", "Authorization": "Bearer SECRET"]
        r.hasStoredSecrets = true
        r.conflictPolicy = .replace
        r.maxConnections = 2
        r.speedLimit = 5000
        r.startMode = .immediate
        r.queuePosition = 7
        r.scheduledAt = Date(timeIntervalSince1970: 300)
        r.averageSpeed = 99.5
        r.trashedAt = Date(timeIntervalSince1970: 400)
        repo.save(r)
        repo.flush()
        let loaded = try #require(try repo.loadAll().first)
        var expected = r
        expected.customHeaders = ["Accept": "*/*"]    // secrets are never written to SQLite
        #expect(loaded == expected)
    }

    @Test func progressAndQueueOrderUpdates() throws {
        let repo = try DownloadRepository(database: .inMemory())
        let a = sampleRecord("a", position: 0), b = sampleRecord("b", position: 1)
        repo.save(a)
        repo.save(b)
        repo.saveProgress(id: a.id, bytesReceived: 42, segments: [DownloadSegment(index: 0, start: 0, end: 99, completed: 42)])
        repo.saveQueueOrder([(a.id, 1), (b.id, 0)])
        repo.flush()
        let all = try repo.loadAll()
        #expect(all.map(\.fileName) == ["b", "a"])
        #expect(all.last?.bytesReceived == 42)
        #expect(all.last?.segments.first?.completed == 42)
    }

    @Test func deleteCascadesSegments() throws {
        let db = try SQLiteDatabase.inMemory()
        let repo = try DownloadRepository(database: db)
        var a = sampleRecord()
        a.segments = [DownloadSegment(index: 0, start: 0, end: 9)]
        repo.save(a)
        repo.delete(ids: [a.id])
        repo.flush()
        #expect(try repo.loadAll().isEmpty)
        #expect(try db.query("SELECT COUNT(*) FROM download_segments;").first?.int(0) == 0)
    }

    @Test func duplicateSaveDoesNotDuplicateRows() throws {
        let repo = try DownloadRepository(database: .inMemory())
        var a = sampleRecord()
        repo.save(a)
        a.state = .paused
        repo.save(a)
        repo.flush()
        let all = try repo.loadAll()
        #expect(all.count == 1)
        #expect(all.first?.state == .paused)
    }

    @Test func settingsPersistAndValidate() throws {
        let dir = TempDir()
        do {
            let repo = try DownloadRepository(directory: dir.url)
            var s = AppSettings()
            s.maxConcurrentDownloads = 99           // clamped to 10
            s.maxConnectionsPerDownload = 0         // clamped to 1
            s.connectionTimeout = .nan              // replaced with a safe default
            s.conflictPolicy = .skip
            s.appearance = .dark
            s.schedule.enabled = true
            s.schedule.weekdays = [2, 9]
            repo.saveSettings(s)
            repo.flush()
        }
        let reopened = try DownloadRepository(directory: dir.url)
        let loaded = try #require(reopened.loadSettings())
        #expect(loaded.maxConcurrentDownloads == 10)
        #expect(loaded.maxConnectionsPerDownload == 1)
        #expect(loaded.connectionTimeout == 30)
        #expect(loaded.conflictPolicy == .skip)
        #expect(loaded.appearance == .dark)
        #expect(loaded.schedule.weekdays == [2])
    }

    @Test func settingsDecodeToleratesMissingKeys() throws {
        let partial = Data(#"{"maxConcurrentDownloads": 5, "unknownFutureKey": true}"#.utf8)
        let s = try JSONDecoder().decode(AppSettings.self, from: partial)
        #expect(s.maxConcurrentDownloads == 5)
        #expect(s.maxConnectionsPerDownload == AppSettings().maxConnectionsPerDownload)
        #expect(s.categories.count == FileCategory.defaults.count)
    }

    @Test func diagnosticEventsAreStoredPerDownload() throws {
        let repo = try DownloadRepository(database: .inMemory())
        let id = UUID()
        repo.logEvent(downloadID: id, level: "info", message: "one")
        repo.logEvent(downloadID: id, level: "error", message: "two")
        repo.logEvent(downloadID: UUID(), level: "info", message: "other")
        let events = repo.events(for: id, limit: 10)
        #expect(events.map(\.message) == ["two", "one"])
    }
}

@Suite("Destinations and finalization")
struct FileSystemTests {
    @Test func conflictRenameKeepsBoth() throws {
        let dir = TempDir()
        try Data("old".utf8).write(to: dir.file("a.txt"))
        let partial = dir.file("p1")
        try Data("new".utf8).write(to: partial)
        let final = try FileFinalizer().finalize(partial: partial, directory: dir.url, fileName: "a.txt", policy: .rename, quarantine: nil)
        #expect(final.lastPathComponent == "a (1).txt")
        #expect(try String(contentsOf: dir.file("a.txt"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: final, encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func conflictReplaceMovesOldFileToTrash() throws {
        let dir = TempDir()
        let target = dir.file("r-\(UUID().uuidString).txt")
        try Data("old".utf8).write(to: target)
        let partial = dir.file("p2")
        try Data("new".utf8).write(to: partial)
        let final = try FileFinalizer().finalize(partial: partial, directory: dir.url, fileName: target.lastPathComponent, policy: .replace, quarantine: nil)
        #expect(final == target)
        #expect(try String(contentsOf: final, encoding: .utf8) == "new")
    }

    @Test func skipPolicyNeverDropsDownloadedData() throws {
        let dir = TempDir()
        try Data("old".utf8).write(to: dir.file("s.txt"))
        let partial = dir.file("p3")
        try Data("new".utf8).write(to: partial)
        let final = try FileFinalizer().finalize(partial: partial, directory: dir.url, fileName: "s.txt", policy: .skip, quarantine: nil)
        #expect(final.lastPathComponent == "s (1).txt")
    }

    @Test func hostileNameCannotEscapeDirectory() throws {
        let dir = TempDir()
        let sub = dir.url.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        let partial = dir.file("p4")
        try Data("x".utf8).write(to: partial)
        let final = try FileFinalizer().finalize(partial: partial, directory: sub, fileName: "../../escape.sh", policy: .rename, quarantine: nil)
        #expect(final.deletingLastPathComponent().standardizedFileURL.path == sub.standardizedFileURL.path)
        #expect(final.lastPathComponent == "escape.sh")
    }

    @Test func quarantineIsApplied() throws {
        let dir = TempDir()
        let partial = dir.file("q")
        try Data("x".utf8).write(to: partial)
        let final = try FileFinalizer().finalize(partial: partial, directory: dir.url, fileName: "q.bin", policy: .rename,
                                                 quarantine: .init(sourceURL: URL(string: "https://example.com/q.bin")!, pageURL: nil))
        let props = try final.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(props?["LSQuarantineAgentName"] as? String == "OleDownloadManager")
    }

    @Test func missingDestinationIsNeverCreated() {
        let manager = DestinationManager()
        let ghost = URL(fileURLWithPath: "/Volumes/OleDMNoSuchDrive-\(UUID().uuidString)/Downloads", isDirectory: true)
        guard case .unavailable(let reason) = manager.availability(of: ghost) else {
            Issue.record("expected unavailable")
            return
        }
        #expect(reason.contains("not connected"))
        #expect(throws: DownloadError.self) { try manager.ensureSubdirectory(of: ghost, named: "x") }
        #expect(!FileManager.default.fileExists(atPath: ghost.path))
    }

    @Test func volumeMismatchIsDetected() {
        let dir = TempDir()
        let manager = DestinationManager()
        #expect(manager.availability(of: dir.url) == .available)
        if case .unavailable = manager.availability(of: dir.url, expectedVolumeUUID: "00000000-0000-0000-0000-000000000000") {} else {
            Issue.record("a different volume UUID must be reported")
        }
    }

    @Test func categoryFoldersAndPartialFolder() throws {
        let dir = TempDir()
        let manager = DestinationManager()
        var s = AppSettings()
        s.organizeByCategory = true
        let video = try manager.resolvedDirectory(root: dir.url, categoryID: "video", settings: s)
        #expect(video.lastPathComponent == "Video")
        let partial = try manager.partialDirectory(for: video, settings: s)
        #expect(partial.lastPathComponent == DestinationManager.partialFolderName)
        manager.cleanUpPartialDirectory(partial)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func diskSpaceEstimate() {
        let dir = TempDir()
        #expect(DiskSpace.check(directory: dir.url, expectedLength: nil, alreadyReceived: 0, availableOverride: 1) == nil)
        #expect(DiskSpace.check(directory: dir.url, expectedLength: 1_000_000_000, alreadyReceived: 0, availableOverride: 500_000_000)?.kind == .diskFull)
        #expect(DiskSpace.check(directory: dir.url, expectedLength: 1_000_000_000, alreadyReceived: 990_000_000, availableOverride: 500_000_000) == nil)
        #expect(DiskSpace.required(expectedLength: 100, alreadyReceived: 0) >= 100)
    }

    @Test func sha256Streaming() throws {
        let dir = TempDir()
        try Data("hello".utf8).write(to: dir.file("h"))
        #expect(try IntegrityVerifier.sha256(of: dir.file("h"), chunkSize: 2) == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        #expect(IntegrityVerifier.normalizeSHA256("SHA256: 2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824") == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        #expect(IntegrityVerifier.normalizeSHA256("xyz") == nil)
    }
}
