import Foundation
import Testing
@testable import OleDownloadCore
import OleBrowserBridge

@MainActor
final class CoordinatorHarness {
    let server: TestHTTPServer
    let dir = TempDir()
    let dbDir: URL
    let downloads: URL
    var repo: DownloadRepository
    var coordinator: DownloadCoordinator
    let secrets = InMemorySecretStore()

    init(configure: (inout AppSettings) -> Void = { _ in }) throws {
        server = try TestHTTPServer()
        dbDir = dir.url.appendingPathComponent("db", isDirectory: true)
        downloads = dir.url.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        repo = try DownloadRepository(directory: dbDir)
        var s = AppSettings()
        s.defaultDirectoryPath = downloads.path
        s.retryBaseDelay = 0.5
        s.retryMaxDelay = 1
        s.maxRetries = 3
        configure(&s)
        repo.saveSettings(s)
        repo.flush()
        coordinator = DownloadCoordinator(environment: Self.environment(repo: repo, secrets: secrets))
        coordinator.start()
    }

    static func environment(repo: DownloadRepository, secrets: SecretStore) -> CoordinatorEnvironment {
        var env = CoordinatorEnvironment(store: repo, secrets: secrets)
        env.minimumSegmentSize = 64 * 1024
        env.tickInterval = 0.05
        env.checkpointInterval = 0.2
        return env
    }

    /// Simulates quitting and relaunching the app against the same database.
    func relaunch() async throws {
        await coordinator.shutdown()
        repo = try DownloadRepository(directory: dbDir)
        coordinator = DownloadCoordinator(environment: Self.environment(repo: repo, secrets: secrets))
        coordinator.start()
    }

    @discardableResult
    func add(_ path: String, action: AddAction = .startNow, configure: (inout NewDownloadRequest) -> Void = { _ in }) throws -> DownloadItem {
        var r = NewDownloadRequest(url: server.url(path))
        r.action = action
        configure(&r)
        return try coordinator.add(r).get()
    }

    func waitFor(_ item: DownloadItem, _ state: DownloadState, timeout: TimeInterval = 20) async -> Bool {
        await waitUntilMain(timeout: timeout) { item.state == state }
    }
}

@Suite("Download coordinator", .serialized)
@MainActor
struct CoordinatorTests {
    @Test func downloadsToChosenDirectoryAndPersistsHistory() async throws {
        let h = try CoordinatorHarness()
        let item = try h.add("/file?size=800000&seed=21&disposition=report.bin")
        #expect(await h.waitFor(item, .completed))
        let file = try #require(item.record.finalFileURL)
        #expect(file.deletingLastPathComponent().standardizedFileURL.path == h.downloads.standardizedFileURL.path)
        #expect(file.lastPathComponent == "report.bin")
        #expect(try Data(contentsOf: file) == TestHTTPServer.body(size: 800000, seed: 21))
        #expect(item.record.sha256?.count == 64)
        #expect(item.record.completedAt != nil)
        #expect(item.record.partialFileURL == nil)
        // The hidden partial folder is cleaned up.
        #expect(!FileManager.default.fileExists(atPath: h.downloads.appendingPathComponent(DestinationManager.partialFolderName).path))

        try await h.relaunch()
        let reloaded = try #require(h.coordinator.item(item.id))
        #expect(reloaded.state == .completed)
        #expect(reloaded.record.finalFileURL == file)
        #expect(!reloaded.fileMissing)
    }

    @Test func pauseAndResume() async throws {
        let h = try CoordinatorHarness()
        let item = try h.add("/file?size=1500000&seed=22&chunkSize=16384&delayMs=10")
        #expect(await waitUntilMain { item.record.bytesReceived > 200_000 })
        // Live statistics come from real transferred bytes.
        #expect(await waitUntilMain { item.state == .downloading && item.currentSpeed > 0 && h.coordinator.totalSpeed > 0 })
        #expect(await waitUntilMain { item.eta != nil })
        #expect(item.record.progressFraction.map { $0 > 0 && $0 < 1 } == true)
        h.coordinator.pause([item.id])
        #expect(await h.waitFor(item, .paused))
        #expect(!h.coordinator.isRunning(item.id))
        let pausedBytes = item.record.bytesReceived
        #expect(pausedBytes > 0)
        #expect(!item.record.segments.isEmpty)
        #expect(item.record.supportsRanges == true)
        // Network activity has stopped: the byte count does not move while paused.
        try await Task.sleep(for: .milliseconds(300))
        #expect(item.record.bytesReceived == pausedBytes)

        h.coordinator.resume([item.id])
        #expect(await h.waitFor(item, .completed, timeout: 30))
        #expect(try Data(contentsOf: try #require(item.record.finalFileURL)) == TestHTTPServer.body(size: 1500000, seed: 22))
    }

    @Test func cancelDeletesPartialDataAndRestartWorks() async throws {
        let h = try CoordinatorHarness()
        let item = try h.add("/file?size=1000000&seed=23&chunkSize=16384&delayMs=10")
        #expect(await waitUntilMain { item.record.bytesReceived > 100_000 })
        let partial = try #require(item.record.partialFileURL)
        h.coordinator.cancel([item.id], deletePartialData: true)
        #expect(await h.waitFor(item, .canceled))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(item.record.bytesReceived == 0)
        // Canceled items never come back on their own, even when the queue runs.
        h.coordinator.startQueue()
        try await Task.sleep(for: .milliseconds(300))
        #expect(item.state == .canceled)

        h.coordinator.restart([item.id])
        #expect(await h.waitFor(item, .completed, timeout: 30))
    }

    @Test func permanentFailureIsNotRetried() async throws {
        let h = try CoordinatorHarness()
        let item = try h.add("/status/404")
        #expect(await h.waitFor(item, .failed))
        #expect(item.record.lastError?.kind == .notFound)
        #expect(item.record.retryCount == 0)
        #expect(item.record.httpStatus == 404)
        #expect(h.server.requests(path: "/status/404").count == 1)
    }

    @Test func transientFailureRetriesWithBackoff() async throws {
        let h = try CoordinatorHarness()
        let item = try h.add("/file?size=5000&seed=24&fail500=2&key=coord")
        #expect(await h.waitFor(item, .completed, timeout: 30))
        #expect(item.record.retryCount == 2)
    }

    @Test func manualRetryAfterFailure() async throws {
        let h = try CoordinatorHarness { $0.maxRetries = 0 }
        let item = try h.add("/file?size=5000&seed=25&fail500=1&key=manual")
        #expect(await h.waitFor(item, .failed))
        #expect(item.record.lastError?.kind == .serverError)
        h.coordinator.retry([item.id])
        #expect(await h.waitFor(item, .completed))
        #expect(item.record.lastError == nil)
    }

    @Test func queueRespectsConcurrencyLimitAndOrder() async throws {
        let h = try CoordinatorHarness { $0.maxConcurrentDownloads = 2 }
        var items: [DownloadItem] = []
        for i in 0..<5 {
            items.append(try h.add("/file?size=200000&seed=\(30 + i)&chunkSize=16384&delayMs=5", action: .addToQueue))
        }
        // Nothing starts until the queue is started.
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.coordinator.activeCount == 0)
        #expect(items.allSatisfy { $0.state == .queued })

        h.coordinator.move(items[4].id, by: -4)   // last item to the front
        #expect(h.coordinator.queuedIDsInOrder.first == items[4].id)

        h.coordinator.startQueue()
        var maxActive = 0
        var firstBatch: Set<UUID> = []
        let done = await waitUntilMain(timeout: 60) {
            maxActive = max(maxActive, h.coordinator.activeCount)
            if firstBatch.isEmpty { firstBatch = Set(items.filter { $0.state != .queued }.map(\.id)) }
            return items.allSatisfy { $0.state == .completed }
        }
        #expect(done, "states: \(items.map { "\($0.state.rawValue) \($0.record.bytesReceived)/\($0.record.expectedLength ?? -1) running=\(h.coordinator.isRunning($0.id)) err=\($0.record.lastError?.description ?? "-")" })")
        #expect(maxActive <= 2)
        #expect(maxActive == 2)
        #expect(firstBatch.contains(items[4].id))
        #expect(!firstBatch.contains(items[3].id))
    }

    @Test func pauseQueueReturnsQueueItemsToWaiting() async throws {
        let h = try CoordinatorHarness { $0.maxConcurrentDownloads = 1 }
        let item = try h.add("/file?size=1000000&seed=40&chunkSize=16384&delayMs=10", action: .addToQueue)
        h.coordinator.startQueue()
        #expect(await waitUntilMain { item.record.bytesReceived > 50_000 })
        h.coordinator.pauseQueue()
        #expect(await h.waitFor(item, .queued))
        #expect(!h.coordinator.queueRunning)
        #expect(item.record.bytesReceived > 0)
        h.coordinator.startQueue()
        #expect(await h.waitFor(item, .completed, timeout: 30))
    }

    @Test func conflictRenamesNewFile() async throws {
        let h = try CoordinatorHarness()
        try Data("existing".utf8).write(to: h.downloads.appendingPathComponent("same.bin"))
        let item = try h.add("/file?size=1000&seed=41&disposition=same.bin")
        #expect(await h.waitFor(item, .completed))
        #expect(item.record.finalFileURL?.lastPathComponent == "same (1).bin")
        #expect(try String(contentsOf: h.downloads.appendingPathComponent("same.bin"), encoding: .utf8) == "existing")
    }

    @Test func skipPolicyRejectsExistingFile() throws {
        let h = try CoordinatorHarness { $0.conflictPolicy = .skip }
        try Data("existing".utf8).write(to: h.downloads.appendingPathComponent("skip.bin"))
        var r = NewDownloadRequest(url: h.server.url("/file?size=10"))
        r.fileName = "skip.bin"
        #expect(throws: AddDownloadError.skippedExistingFile("skip.bin")) { try h.coordinator.add(r).get() }
    }

    @Test func duplicateURLIsDetected() throws {
        let h = try CoordinatorHarness()
        let first = try h.add("/file?size=10&seed=1", action: .addToQueue)
        #expect(throws: AddDownloadError.duplicate(first.id)) { try h.add("/file?size=10&seed=1", action: .addToQueue) }
    }

    @Test func interruptedDownloadSurvivesRelaunchAndResumes() async throws {
        let h = try CoordinatorHarness()
        let item = try h.add("/file?size=1500000&seed=42&chunkSize=16384&delayMs=10")
        #expect(await waitUntilMain { item.record.bytesReceived > 300_000 })
        try await h.relaunch()

        let restored = try #require(h.coordinator.item(item.id))
        #expect(restored.state == .interrupted)          // not restarted without user action
        #expect(!restored.record.segments.isEmpty)
        let savedBytes = restored.record.bytesReceived
        #expect(savedBytes > 0)
        try await Task.sleep(for: .milliseconds(200))
        #expect(restored.state == .interrupted)

        let requestsBefore = h.server.requests.count
        h.coordinator.resume([restored.id])
        #expect(await h.waitFor(restored, .completed, timeout: 30))
        #expect(try Data(contentsOf: try #require(restored.record.finalFileURL)) == TestHTTPServer.body(size: 1500000, seed: 42))
        // The resumed run did not start over from byte zero.
        #expect(!h.server.requests.dropFirst(requestsBefore).contains { $0.headers["range"] == "bytes=0-" })
    }

    @Test func autoResumeSettingRestartsInterruptedDownloads() async throws {
        let h = try CoordinatorHarness { $0.resumeInterruptedOnLaunch = true }
        let item = try h.add("/file?size=600000&seed=43&chunkSize=16384&delayMs=10")
        #expect(await waitUntilMain { item.record.bytesReceived > 50_000 })
        try await h.relaunch()
        let restored = try #require(h.coordinator.item(item.id))
        #expect(await h.waitFor(restored, .completed, timeout: 30))
    }

    @Test func queuedItemsSurviveRelaunch() async throws {
        let h = try CoordinatorHarness()
        let a = try h.add("/file?size=10&seed=1", action: .addToQueue)
        let b = try h.add("/file?size=10&seed=2", action: .addToQueue)
        h.coordinator.move(b.id, by: -1)
        try await h.relaunch()
        #expect(h.coordinator.queuedIDsInOrder == [b.id, a.id])
        #expect(!h.coordinator.queueRunning)
    }

    @Test func missingDestinationWaitsInsteadOfFallingBack() async throws {
        let h = try CoordinatorHarness()
        let external = h.dir.url.appendingPathComponent("FakeExternalDrive", isDirectory: true)
        var r = NewDownloadRequest(url: h.server.url("/file?size=3000&seed=44"))
        r.directory = external   // does not exist yet: like an unplugged drive
        r.action = .startNow
        let item = try h.coordinator.add(r).get()
        #expect(await h.waitFor(item, .waitingForDestination))
        #expect(!FileManager.default.fileExists(atPath: external.path))   // never created behind the user's back

        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)   // "drive reconnected"
        h.coordinator.destinationsChanged()
        #expect(await h.waitFor(item, .completed))
        #expect(item.record.finalFileURL?.deletingLastPathComponent().lastPathComponent == "FakeExternalDrive")
    }

    @Test func checksumMismatchFails() async throws {
        let h = try CoordinatorHarness()
        let item = try h.add("/file?size=1000&seed=45") { $0.expectedSHA256 = String(repeating: "0", count: 64) }
        #expect(await h.waitFor(item, .failed))
        #expect(item.record.lastError?.kind == .checksumMismatch)
        #expect(item.record.checksumVerified == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.downloads.path).filter { !$0.hasPrefix(".") }.isEmpty)
    }

    @Test func checksumMatchIsRecorded() async throws {
        let h = try CoordinatorHarness()
        let body = TestHTTPServer.body(size: 1000, seed: 46)
        let tmp = h.dir.file("expected")
        try body.write(to: tmp)
        let expected = try IntegrityVerifier.sha256(of: tmp)
        let item = try h.add("/file?size=1000&seed=46") { $0.expectedSHA256 = expected.uppercased() }
        #expect(await h.waitFor(item, .completed))
        #expect(item.record.checksumVerified == true)
    }

    @Test func organizeByCategory() async throws {
        let h = try CoordinatorHarness { $0.organizeByCategory = true }
        let item = try h.add("/file?size=100&seed=47&disposition=clip.mp4")
        #expect(await h.waitFor(item, .completed))
        #expect(item.record.categoryID == "video")
        #expect(item.record.finalFileURL?.deletingLastPathComponent().lastPathComponent == "Video")
    }

    @Test func trashRestoreAndDelete() async throws {
        let h = try CoordinatorHarness()
        let item = try h.add("/file?size=100&seed=48")
        #expect(await h.waitFor(item, .completed))
        h.coordinator.moveToTrash([item.id])
        #expect(item.record.isTrashed)
        h.coordinator.restoreFromTrash([item.id])
        #expect(!item.record.isTrashed)
        h.coordinator.moveToTrash([item.id])
        h.coordinator.emptyTrash()
        #expect(h.coordinator.item(item.id) == nil)
        h.repo.flush()
        #expect(try h.repo.loadAll().isEmpty)
        // History removal never deletes the downloaded file unless asked to.
        #expect(FileManager.default.fileExists(atPath: item.record.finalFileURL!.path))
    }

    @Test func credentialsStayOutOfDatabase() async throws {
        let h = try CoordinatorHarness()
        let item = try h.add("/file?size=10&seed=49", action: .addToQueue) {
            $0.headers = ["Authorization": "Bearer TOPSECRET", "X-Custom": "1"]
            $0.secrets = DownloadSecrets(user: "alice", password: "pw")
            $0.rememberSecrets = true
        }
        h.repo.flush()
        let raw = try String(contentsOf: h.dbDir.appendingPathComponent("OleDownloadManager.sqlite"), encoding: .isoLatin1)
        #expect(!raw.contains("TOPSECRET"))
        #expect(!raw.contains("\"pw\""))
        #expect(h.secrets.load(for: item.id)?.sensitiveHeaders["Authorization"] == "Bearer TOPSECRET")
        #expect(item.record.customHeaders == ["X-Custom": "1"])
        #expect(item.record.hasStoredSecrets)
    }

    @Test func browserBridgeAddsAndRejects() async throws {
        let h = try CoordinatorHarness { $0.browserCaptureAction = .addToQueue }
        let origin = "chrome-extension://adndpcefokbkijmccnbhfkhllcpedgfj/"
        func send(_ json: [String: Any]) throws -> BrowserMessage {
            let data = try JSONSerialization.data(withJSONObject: json)
            return try JSONDecoder().decode(BrowserMessage.self, from: h.coordinator.handleBrowserMessage(data))
        }
        let url = h.server.url("/file?size=10&seed=50").absoluteString
        let status = try send(["v": 1, "type": "hello", "id": "h1", "browser": "chrome", "origin": origin])
        #expect(status.type == .status)
        #expect(status.connected == true)
        #expect(h.coordinator.lastBrowserContact["chrome"] != nil)

        let accepted = try send(["v": 1, "type": "addDownload", "id": "a1", "url": url, "fileName": "../evil.bin", "source": "contextMenu", "origin": origin])
        #expect(accepted.type == .downloadAccepted)
        let item = try #require(h.coordinator.items.first { $0.id.uuidString == accepted.downloadId })
        #expect(item.record.fileName == "evil.bin")
        #expect(item.record.origin == .browser)
        #expect(item.state == .queued)    // app setting: captured downloads go to the queue

        let dup = try send(["v": 1, "type": "addDownload", "id": "a2", "url": url, "origin": origin])
        #expect(dup.type == .downloadRejected)
        #expect(dup.reason == "duplicate")

        let unauthorized = try send(["v": 1, "type": "addDownload", "url": url, "origin": "chrome-extension://evil/"])
        #expect(unauthorized.type == .error)
        #expect(unauthorized.code == "unauthorizedOrigin")

        var s = h.coordinator.settings
        s.browserCaptureEnabled = false
        h.coordinator.updateSettings(s)
        let off = try send(["v": 1, "type": "addDownload", "url": h.server.url("/file?size=10&seed=51").absoluteString, "source": "interception", "origin": origin])
        #expect(off.reason == "captureDisabled")
    }

    @Test func databaseStaysConsistentAfterErrors() async throws {
        let h = try CoordinatorHarness { $0.maxRetries = 0 }
        let bad = try h.add("/status/500")
        let good = try h.add("/file?size=100&seed=52")
        #expect(await h.waitFor(bad, .failed))
        #expect(await h.waitFor(good, .completed))
        try await h.relaunch()
        let records = try h.repo.loadAll()
        #expect(records.count == 2)
        #expect(Set(records.map(\.id)).count == 2)
        #expect(records.first { $0.id == bad.id }?.state == .failed)
        #expect(records.first { $0.id == good.id }?.state == .completed)
        #expect(Set(records.map(\.queuePosition)).count == 2)
    }
}

@Suite("Queue scheduling")
struct QueueSchedulingTests {
    func candidate(_ pos: Int, _ state: DownloadState = .queued, mode: StartMode = .queue, at: Date? = nil) -> QueueScheduler.Candidate {
        .init(id: UUID(), state: state, startMode: mode, queuePosition: pos, scheduledAt: at, trashed: false)
    }

    @Test func respectsLimitsAndOrder() {
        let c = [candidate(2), candidate(0), candidate(1), candidate(3, .paused)]
        let picked = QueueScheduler.selectToStart(candidates: c, activeCount: 1, maxConcurrent: 3, queueRunning: true, now: Date())
        #expect(picked == [c[1].id, c[2].id])
        #expect(QueueScheduler.selectToStart(candidates: c, activeCount: 3, maxConcurrent: 3, queueRunning: true, now: Date()).isEmpty)
    }

    @Test func stoppedQueueOnlyStartsExplicitItems() {
        let c = [candidate(0), candidate(1, mode: .immediate)]
        #expect(QueueScheduler.selectToStart(candidates: c, activeCount: 0, maxConcurrent: 5, queueRunning: false, now: Date()) == [c[1].id])
    }

    @Test func scheduledItemsWaitForTheirTime() {
        let now = Date()
        let c = [candidate(0, mode: .immediate, at: now.addingTimeInterval(60)), candidate(1, at: now.addingTimeInterval(-1))]
        #expect(QueueScheduler.selectToStart(candidates: c, activeCount: 0, maxConcurrent: 5, queueRunning: false, now: now) == [c[1].id])
    }

    @Test func moving() {
        let ids = [UUID(), UUID(), UUID()]
        #expect(QueueScheduler.move(ids[2], by: -1, in: ids) == [ids[0], ids[2], ids[1]])
        #expect(QueueScheduler.move(ids[0], by: -5, in: ids) == ids)
        #expect(QueueScheduler.move(ids[0], by: 10, in: ids) == [ids[1], ids[2], ids[0]])
    }

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func scheduleStartAndStop() {
        var s = QueueSchedule()
        s.enabled = true
        s.startMinute = 2 * 60
        s.stopEnabled = true
        s.stopMinute = 6 * 60
        #expect(ScheduleEvaluator.action(schedule: s, previousCheck: date(19, 1, 59), now: date(19, 2, 0), calendar: calendar) == .start)
        #expect(ScheduleEvaluator.action(schedule: s, previousCheck: date(19, 2, 0), now: date(19, 2, 1), calendar: calendar) == .none)
        #expect(ScheduleEvaluator.action(schedule: s, previousCheck: date(19, 5, 59), now: date(19, 6, 0), calendar: calendar) == .stop)
        // Asleep across the start time: start on wake, if still inside the window.
        #expect(ScheduleEvaluator.action(schedule: s, previousCheck: date(19, 0), now: date(19, 4), calendar: calendar) == .start)
        // Asleep across the whole window: the later boundary (stop) wins, nothing starts.
        #expect(ScheduleEvaluator.action(schedule: s, previousCheck: date(19, 0), now: date(19, 8), calendar: calendar) == .stop)
        s.enabled = false
        #expect(ScheduleEvaluator.action(schedule: s, previousCheck: date(19, 1, 59), now: date(19, 2, 1), calendar: calendar) == .none)
    }

    @Test func scheduleHonorsWeekdays() {
        var s = QueueSchedule()
        s.enabled = true
        s.startMinute = 120
        s.weekdays = [2]   // Mondays only; 2026-10-19 is a Monday
        #expect(ScheduleEvaluator.action(schedule: s, previousCheck: date(19, 1), now: date(19, 3), calendar: calendar) == .start)
        #expect(ScheduleEvaluator.action(schedule: s, previousCheck: date(20, 1), now: date(20, 3), calendar: calendar) == .none)
        #expect(ScheduleEvaluator.nextStart(schedule: s, after: date(19, 3), calendar: calendar) == date(26, 2))
    }
}
