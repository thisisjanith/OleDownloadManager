import Foundation
import Observation
import OleBrowserBridge

/// Input for a new download, already validated by the caller (UI or browser bridge).
public struct NewDownloadRequest: Sendable {
    public var url: URL
    public var fileName: String?
    public var directory: URL?
    public var categoryID: String?
    public var headers: [String: String] = [:]
    public var secrets = DownloadSecrets()
    public var rememberSecrets = false
    public var action: AddAction = .startNow
    public var origin: DownloadOrigin = .user
    public var pageURL: String?
    public var referrer: String?
    public var expectedSHA256: String?
    public var scheduledAt: Date?
    public var conflictPolicy: ConflictPolicy?
    public var maxConnections: Int?
    public var allowDuplicate = false

    public init(url: URL) { self.url = url }
}

public enum AddDownloadError: Error, Equatable, CustomStringConvertible {
    case duplicate(UUID)
    case skippedExistingFile(String)
    case invalidChecksum
    case keychain(String)

    public var description: String {
        switch self {
        case .duplicate: "This URL is already in the download list."
        case .skippedExistingFile(let name): "“\(name)” already exists in the destination folder, and the conflict policy is set to skip."
        case .invalidChecksum: "The checksum must be a 64-character SHA-256 hex string."
        case .keychain(let m): m
        }
    }
}

public enum CoordinatorEvent: Sendable {
    case completed(id: UUID, fileName: String, fileURL: URL)
    case failed(id: UUID, fileName: String, message: String)
}

/// Dependencies, injectable for tests.
public struct CoordinatorEnvironment: Sendable {
    public var store: DownloadStore
    public var engine: DownloadEngine
    public var secrets: SecretStore
    public var destinations = DestinationManager()
    public var finalizer = FileFinalizer()
    public var minimumSegmentSize: Int64 = 1 << 20
    public var tickInterval: TimeInterval = 0.25
    public var checkpointInterval: TimeInterval = 2
    public var freeSpaceOverride: Int64?

    public init(store: DownloadStore, engine: DownloadEngine = HTTPDownloadEngine(), secrets: SecretStore = KeychainSecretStore()) {
        self.store = store
        self.engine = engine
        self.secrets = secrets
    }
}

/// Central owner of all downloads. Lives on the main actor; transfers run off the main actor in the
/// engine. Every state change goes through `DownloadStateMachine` and is persisted immediately.
@MainActor
@Observable
public final class DownloadCoordinator {
    public private(set) var items: [DownloadItem] = []
    public private(set) var settings: AppSettings
    public private(set) var queueRunning = false
    public private(set) var totalSpeed: Double = 0
    public private(set) var lastBrowserContact: [String: Date] = [:]
    /// Live per-segment progress for the details inspector (not persisted until fsync'ed).
    public private(set) var liveSegments: [UUID: [DownloadSegment]] = [:]
    public var onEvent: (@MainActor (CoordinatorEvent) -> Void)?

    @ObservationIgnored private let env: CoordinatorEnvironment
    @ObservationIgnored private var jobs: [UUID: ActiveJob] = [:]
    @ObservationIgnored private var sessionSecrets: [UUID: DownloadSecrets] = [:]
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastScheduleCheck = Date()
    @ObservationIgnored private var recentBrowserURLs: [String: Date] = [:]
    @ObservationIgnored private let globalLimiter: BandwidthLimiter
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private let log = AppLog.coordinator

    private enum StopReason { case pause, requeue, cancel(deleteData: Bool), trash, waitForDestination, shutdown }

    private final class ActiveJob {
        let id: UUID
        let progress = TransferProgress()
        var task: Task<Void, Never>?
        var stopReason: StopReason?
        var speed = SpeedMonitor()
        var lastCheckpoint = Date()
        var sessionStart = Date()
        var sessionStartBytes: Int64 = 0
        var lastResponse: TransferProgress.ResponseInfo?
        let limiter: BandwidthLimiter
        init(id: UUID, limit: Int64) {
            self.id = id
            limiter = BandwidthLimiter(bytesPerSecond: limit)
        }
    }

    public init(environment: CoordinatorEnvironment) {
        env = environment
        let loaded = environment.store.loadSettings() ?? AppSettings()
        settings = loaded
        globalLimiter = BandwidthLimiter(bytesPerSecond: loaded.globalSpeedLimit)
    }

    // MARK: Lookup

    public func item(_ id: UUID) -> DownloadItem? { items.first { $0.id == id } }
    public var activeCount: Int { jobs.count }
    public func isRunning(_ id: UUID) -> Bool { jobs[id] != nil }

    public func events(for id: UUID) -> [DiagnosticEvent] { env.store.events(for: id, limit: 50) }

    // MARK: Startup and shutdown

    /// Loads persisted downloads and reconciles them with the file system. Interrupted transfers are
    /// only restarted automatically when the user enabled "Resume interrupted downloads at launch".
    public func start() {
        let records = (try? env.store.loadAll()) ?? []
        items = records.map { record in
            let reconciled = reconcile(record)
            if reconciled != record { env.store.save(reconciled) }
            let item = DownloadItem(record: reconciled)
            if reconciled.state == .completed, let url = reconciled.finalFileURL {
                item.fileMissing = !FileManager.default.fileExists(atPath: url.path)
            }
            return item
        }
        normalizeQueuePositions()
        if settings.resumeInterruptedOnLaunch {
            for item in items where item.state == .interrupted && !item.record.isTrashed {
                setState(item, .queued)
                item.record.startMode = .immediate
                env.store.save(item.record)
            }
        }
        queueRunning = settings.startQueueOnLaunch
        lastScheduleCheck = Date()
        startTicker()
        pump()
    }

    func reconcile(_ record: DownloadRecord) -> DownloadRecord {
        var r = record
        switch r.state {
        case .connecting, .downloading, .retrying, .verifying:
            r.state = .interrupted
            r.lastError = DownloadError(.connectionLost, "OleDownloadManager quit before this download finished.")
        default:
            break
        }
        guard !r.state.isTerminal else { return r }
        let destinationAvailable = env.destinations.availability(of: r.destinationDirectory, expectedVolumeUUID: r.destinationVolumeUUID) == .available
        if destinationAvailable, r.bytesReceived > 0 || !r.segments.isEmpty {
            let partialExists = r.partialFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            let tilingOK = r.segments.isEmpty || (r.expectedLength.map { SegmentPlanner.isValidTiling(r.segments, totalLength: $0) } ?? false)
            let resumable = r.supportsRanges == true && !r.segments.isEmpty
            if !partialExists || !tilingOK || !resumable {
                if !partialExists, r.bytesReceived > 0 {
                    env.store.logEvent(downloadID: r.id, level: "warning", message: "Partial data was missing at launch; the download will start over.")
                }
                r.segments = []
                r.bytesReceived = 0
            }
        }
        return r
    }

    /// Pauses every running transfer, persists checkpoints and flushes the database.
    /// Paused-by-quit downloads are marked Interrupted.
    public func shutdown() async {
        isShuttingDown = true
        ticker?.cancel()
        let running = Array(jobs.values)
        for job in running {
            job.stopReason = .shutdown
            job.task?.cancel()
        }
        for job in running {
            await job.task?.value
            completeStop(job)
        }
        env.store.flush()
    }

    // MARK: Settings

    public func updateSettings(_ new: AppSettings) {
        let validated = new.validated()
        guard validated != settings else { return }
        settings = validated
        globalLimiter.setRate(validated.globalSpeedLimit)
        for (id, job) in jobs {
            job.limiter.setRate(item(id)?.record.speedLimit ?? validated.perDownloadSpeedLimit)
        }
        env.store.saveSettings(validated)
        pump()
    }

    // MARK: Adding

    @discardableResult
    public func add(_ request: NewDownloadRequest) -> Result<DownloadItem, AddDownloadError> {
        if !request.allowDuplicate, let existing = items.first(where: { $0.record.sourceURL == request.url && !$0.record.isTrashed && $0.state != .completed && $0.state != .canceled }) {
            return .failure(.duplicate(existing.id))
        }
        var expectedHash: String?
        if let raw = request.expectedSHA256, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let normalized = IntegrityVerifier.normalizeSHA256(raw) else { return .failure(.invalidChecksum) }
            expectedHash = normalized
        }
        let root = request.directory ?? env.destinations.defaultDirectory(settings: settings)
        let suggested = request.fileName.map { FileNameSanitizer.sanitize($0) }
            ?? FileNameSanitizer.suggestedName(contentDisposition: nil, url: request.url, mimeType: nil)
        let categoryID = request.categoryID ?? FileCategory.classify(fileName: suggested, categories: settings.categories)
        let policy = request.conflictPolicy ?? settings.conflictPolicy
        if policy == .skip, finalDirectoryIfAvailable(root: root, categoryID: categoryID).map({ FileManager.default.fileExists(atPath: $0.appendingPathComponent(suggested).path) }) == true {
            return .failure(.skippedExistingFile(suggested))
        }

        var record = DownloadRecord(sourceURL: request.url, fileName: suggested, destinationDirectory: root, categoryID: categoryID)
        record.fileNameIsUserProvided = request.fileName != nil
        record.destinationVolumeUUID = env.destinations.volumeUUID(of: root)
        record.customHeaders = request.headers.filter { !Redactor.isSensitiveHeader($0.key) }
        record.origin = request.origin
        record.pageURL = request.pageURL
        record.referrer = request.referrer
        record.expectedSHA256 = expectedHash
        record.scheduledAt = request.scheduledAt
        record.conflictPolicy = request.conflictPolicy
        record.maxConnections = request.maxConnections
        record.startMode = request.action == .startNow ? .immediate : .queue
        record.queuePosition = (items.map(\.record.queuePosition).max() ?? -1) + 1

        var secrets = request.secrets
        for (k, v) in request.headers where Redactor.isSensitiveHeader(k) { secrets.sensitiveHeaders[k] = v }
        if !secrets.isEmpty {
            sessionSecrets[record.id] = secrets
            if request.rememberSecrets {
                do {
                    try env.secrets.save(secrets, for: record.id)
                    record.hasStoredSecrets = true
                } catch {
                    return .failure(.keychain(DownloadError.from(error).message))
                }
            }
        }
        let item = DownloadItem(record: record)
        items.append(item)
        env.store.save(record)
        env.store.logEvent(downloadID: record.id, level: "info", message: "Added from \(record.origin.label.lowercased()): \(Redactor.redact(record.sourceURL))")
        pump()
        return .success(item)
    }

    private func finalDirectoryIfAvailable(root: URL, categoryID: String) -> URL? {
        guard env.destinations.availability(of: root) == .available else { return nil }
        guard settings.organizeByCategory, let c = settings.categories.first(where: { $0.id == categoryID }) else { return root }
        return root.appendingPathComponent(FileNameSanitizer.sanitize(c.folderName, fallback: "Other"), isDirectory: true)
    }

    // MARK: User actions

    /// Start or resume: moves the items to the front of the line, regardless of whether the queue runs.
    public func start(_ ids: [UUID]) {
        for id in ids {
            guard let item = item(id), jobs[id] == nil else { continue }
            switch item.state {
            case .queued, .paused, .interrupted, .waitingForDestination, .failed:
                item.record.startMode = .immediate
                item.record.scheduledAt = nil
                if item.state == .failed { item.record.retryCount = 0 }
                if item.state != .queued { setState(item, .queued) }
                env.store.save(item.record)
            default:
                continue
            }
        }
        pump()
    }

    public func resume(_ ids: [UUID]) { start(ids) }

    public func pause(_ ids: [UUID]) {
        for id in ids {
            guard let item = item(id), item.state.canPause else { continue }
            if let job = jobs[id] {
                stop(job, reason: .pause)
            } else {
                setState(item, .paused)
                env.store.save(item.record)
            }
        }
    }

    public func retry(_ ids: [UUID]) {
        for id in ids {
            guard let item = item(id) else { continue }
            if item.state == .retrying, let job = jobs[id] {
                // "Retry Now": skip the remaining backoff.
                stop(job, reason: .requeue) { [weak self] in self?.start([id]) }
                continue
            }
            guard item.state == .failed else { continue }
            item.record.lastError = nil
            start([id])
        }
    }

    public func cancel(_ ids: [UUID], deletePartialData: Bool) {
        for id in ids {
            guard let item = item(id), item.state.canCancel else { continue }
            if let job = jobs[id] {
                stop(job, reason: .cancel(deleteData: deletePartialData))
            } else {
                setState(item, .canceled)
                if deletePartialData { discardPartialData(item) }
                env.store.save(item.record)
            }
        }
    }

    /// Canceled → queued with fresh progress. The only way a canceled download becomes active again.
    public func restart(_ ids: [UUID]) {
        for id in ids {
            guard let item = item(id), item.state == .canceled else { continue }
            discardPartialData(item)
            item.record.retryCount = 0
            item.record.lastError = nil
            item.record.startMode = .immediate
            setState(item, .queued)
            env.store.save(item.record)
        }
        pump()
    }

    /// Removes items from the list (into Trash). Running transfers are paused first.
    public func moveToTrash(_ ids: [UUID]) {
        for id in ids {
            guard let item = item(id), !item.record.isTrashed else { continue }
            if let job = jobs[id] {
                stop(job, reason: .trash)
            } else {
                if item.state == .queued || item.state == .waitingForDestination { setState(item, .paused) }
                item.record.trashedAt = Date()
                env.store.save(item.record)
            }
        }
    }

    public func restoreFromTrash(_ ids: [UUID]) {
        for id in ids {
            guard let item = item(id), item.record.isTrashed else { continue }
            item.record.trashedAt = nil
            env.store.save(item.record)
        }
    }

    /// Permanently forgets downloads. Partial data is always removed; completed files only when asked
    /// (and then they go to the Finder Trash, never deleted outright).
    public func deletePermanently(_ ids: [UUID], moveCompletedFilesToTrash: Bool) {
        var removed: [UUID] = []
        for id in ids {
            guard let item = item(id) else { continue }
            if let job = jobs[id] { stop(job, reason: .cancel(deleteData: true)) }
            discardPartialData(item)
            if moveCompletedFilesToTrash, item.state == .completed, let file = item.record.finalFileURL,
               FileManager.default.fileExists(atPath: file.path) {
                try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
            }
            if item.record.hasStoredSecrets { env.secrets.delete(for: id) }
            sessionSecrets[id] = nil
            removed.append(id)
        }
        items.removeAll { removed.contains($0.id) }
        env.store.delete(ids: removed)
    }

    public func emptyTrash(moveCompletedFilesToTrash: Bool = false) {
        deletePermanently(items.filter(\.record.isTrashed).map(\.id), moveCompletedFilesToTrash: moveCompletedFilesToTrash)
    }

    // MARK: Queue

    public func startQueue() {
        queueRunning = true
        pump()
    }

    /// Stops the queue: no new queued items start, and queue-started transfers go back to Waiting.
    /// Downloads the user started explicitly keep running.
    public func pauseQueue() {
        queueRunning = false
        for (id, job) in jobs where item(id)?.record.startMode == .queue && item(id)?.state != .verifying {
            stop(job, reason: .requeue)
        }
    }

    /// Resumes every paused or interrupted download through the queue.
    public func resumeAll() {
        for item in items where (item.state == .paused || item.state == .interrupted) && !item.record.isTrashed {
            item.record.startMode = .queue
            setState(item, .queued)
            env.store.save(item.record)
        }
        startQueue()
    }

    public var queuedIDsInOrder: [UUID] {
        items.filter { $0.state == .queued && !$0.record.isTrashed }
            .sorted { $0.record.queuePosition < $1.record.queuePosition }
            .map(\.id)
    }

    public func move(_ id: UUID, by offset: Int) {
        reorderQueue(QueueScheduler.move(id, by: offset, in: queuedIDsInOrder))
    }

    /// Applies a new relative order to the given (queued) ids, keeping all other positions.
    public func reorderQueue(_ orderedIDs: [UUID]) {
        let slots = orderedIDs.compactMap { item($0)?.record.queuePosition }.sorted()
        guard slots.count == orderedIDs.count else { return }
        var changes: [(UUID, Int)] = []
        for (id, pos) in zip(orderedIDs, slots) {
            guard let item = item(id), item.record.queuePosition != pos else { continue }
            item.record.queuePosition = pos
            changes.append((id, pos))
        }
        env.store.saveQueueOrder(changes)
        items.sort { $0.record.queuePosition < $1.record.queuePosition }
    }

    private func normalizeQueuePositions() {
        items.sort { ($0.record.queuePosition, $0.record.createdAt) < ($1.record.queuePosition, $1.record.createdAt) }
        var changes: [(UUID, Int)] = []
        for (i, item) in items.enumerated() where item.record.queuePosition != i {
            item.record.queuePosition = i
            changes.append((item.id, i))
        }
        if !changes.isEmpty { env.store.saveQueueOrder(changes) }
    }

    // MARK: External drives

    /// Call when volumes mount or unmount. Waiting downloads restart when their folder is back;
    /// running downloads whose folder vanished stop and wait instead of failing.
    public func destinationsChanged() {
        for (id, job) in jobs {
            guard let item = item(id) else { continue }
            if env.destinations.availability(of: item.record.destinationDirectory, expectedVolumeUUID: item.record.destinationVolumeUUID) != .available {
                stop(job, reason: .waitForDestination)
            }
        }
        for item in items where item.state == .waitingForDestination && !item.record.isTrashed {
            if env.destinations.availability(of: item.record.destinationDirectory, expectedVolumeUUID: item.record.destinationVolumeUUID) == .available {
                env.store.logEvent(downloadID: item.id, level: "info", message: "Destination available again; download queued.")
                item.record.lastError = nil
                setState(item, .queued)
                env.store.save(item.record)
            }
        }
        pump()
    }

    // MARK: Scheduling

    private func pump() {
        guard !isShuttingDown else { return }
        let candidates = items.map {
            QueueScheduler.Candidate(id: $0.id, state: $0.state, startMode: $0.record.startMode, queuePosition: $0.record.queuePosition,
                                     scheduledAt: $0.record.scheduledAt, trashed: $0.record.isTrashed)
        }
        let ids = QueueScheduler.selectToStart(candidates: candidates, activeCount: jobs.count,
                                               maxConcurrent: settings.maxConcurrentDownloads, queueRunning: queueRunning, now: Date())
        for id in ids { launch(id) }
    }

    private func launch(_ id: UUID) {
        guard let item = item(id), jobs[id] == nil else { return }
        let job = ActiveJob(id: id, limit: item.record.speedLimit ?? settings.perDownloadSpeedLimit)
        job.progress.reset(expectedLength: item.record.expectedLength, segments: item.record.segments, bytesReceived: item.record.bytesReceived)
        job.sessionStartBytes = item.record.bytesReceived
        jobs[id] = job
        item.record.scheduledAt = nil
        setState(item, .connecting)
        if item.record.startedAt == nil { item.record.startedAt = Date() }
        env.store.save(item.record)
        job.task = Task { [weak self] in await self?.run(job) }
    }

    private func stop(_ job: ActiveJob, reason: StopReason, then: (@MainActor () -> Void)? = nil) {
        guard job.stopReason == nil else { return }
        job.stopReason = reason
        item(job.id)?.isPausing = true
        job.task?.cancel()
        Task { [weak self] in
            await job.task?.value
            self?.completeStop(job)
            then?()
        }
    }

    /// Runs after the job's task (and therefore the engine) has fully stopped and fsync'ed.
    private func completeStop(_ job: ActiveJob) {
        guard let item = item(job.id) else { jobs[job.id] = nil; return }
        if item.state != .completed && item.state != .failed {
            absorb(job.progress.snapshot(), into: item)
        }
        item.isPausing = false
        switch job.stopReason {
        case .pause?: settle(item, .paused)
        case .requeue?: settle(item, .queued)
        case .cancel(let delete)?:
            settle(item, .canceled)
            if delete || item.record.supportsRanges != true { discardPartialData(item) }
        case .trash?:
            settle(item, .paused)
            item.record.trashedAt = Date()
        case .waitForDestination?:
            item.record.lastError = DownloadError(.destinationUnavailable, "The destination folder became unavailable. The download will continue when it is back.")
            settle(item, .waitingForDestination)
        case .shutdown?:
            settle(item, .interrupted)
        case nil: break
        }
        finishJob(job)
        env.store.save(item.record)
        pump()
    }

    private func finishJob(_ job: ActiveJob) {
        jobs[job.id] = nil
        liveSegments[job.id] = nil
        if let item = item(job.id) {
            item.currentSpeed = 0
            item.smoothedSpeed = 0
            item.eta = nil
            item.activeConnections = 0
            item.nextRetryAt = nil
            let elapsed = Date().timeIntervalSince(job.sessionStart)
            let bytes = item.record.bytesReceived - job.sessionStartBytes
            if elapsed > 1, bytes > 0 { item.record.averageSpeed = Double(bytes) / elapsed }
        }
    }

    // MARK: Transfer job

    private func run(_ job: ActiveJob) async {
        while !Task.isCancelled, let item = item(job.id) {
            let record = item.record
            let root = record.destinationDirectory
            switch env.destinations.availability(of: root, expectedVolumeUUID: record.destinationVolumeUUID) {
            case .available: break
            case .unavailable(let reason):
                item.record.lastError = DownloadError(.destinationUnavailable, reason)
                setState(item, .waitingForDestination)
                env.store.save(item.record)
                finishJob(job)
                return
            case .notWritable(let reason):
                fail(item, job: job, DownloadError(.permissionDenied, reason))
                return
            }
            let partialURL: URL
            do {
                let partialDir = try env.destinations.partialDirectory(for: root, settings: settings)
                partialURL = record.partialFileURL ?? partialDir.appendingPathComponent("\(record.id.uuidString).part")
            } catch {
                fail(item, job: job, DownloadError.from(error))
                return
            }
            if item.record.partialFileURL != partialURL {
                item.record.partialFileURL = partialURL
                env.store.save(item.record)
            }
            if let problem = DiskSpace.check(directory: root, expectedLength: record.expectedLength,
                                             alreadyReceived: record.bytesReceived, availableOverride: env.freeSpaceOverride) {
                fail(item, job: job, problem)
                return
            }

            let secrets = sessionSecrets[job.id] ?? (record.hasStoredSecrets ? env.secrets.load(for: job.id) : nil)
            var headers = record.customHeaders
            for (k, v) in secrets?.sensitiveHeaders ?? [:] { headers[k] = v }
            if let referrer = record.referrer, headers["Referer"] == nil { headers["Referer"] = referrer }
            let resume: ResumeState? = (record.supportsRanges == true && !record.segments.isEmpty)
                ? ResumeState(validators: record.validators, expectedLength: record.expectedLength, supportsRanges: true, segments: record.segments)
                : nil
            let engineJob = EngineJob(url: record.sourceURL, headers: headers, credentials: secrets?.credentials,
                                      partialFile: partialURL, resume: resume)
            let config = engineConfiguration(for: record, job: job)
            job.speed.reset()

            do {
                let result = try await env.engine.download(engineJob, configuration: config, progress: job.progress)
                if job.stopReason != nil { return }
                try await complete(item, job: job, result: result, partialURL: partialURL)
                return
            } catch {
                if job.stopReason != nil || error is CancellationError { return }
                let e = DownloadError.from(error)
                absorb(job.progress.snapshot(), into: item)
                env.store.logEvent(downloadID: job.id, level: "error", message: e.description)
                if e.kind == .destinationUnavailable ||
                    env.destinations.availability(of: root, expectedVolumeUUID: record.destinationVolumeUUID) != .available {
                    item.record.lastError = DownloadError(.destinationUnavailable, "The destination became unavailable. The download will continue when it is reconnected.", detail: e.detail)
                    setState(item, .waitingForDestination)
                    env.store.save(item.record)
                    finishJob(job)
                    pump()
                    return
                }
                if e.kind == .sourceChanged || e.kind == .checksumMismatch || e.kind == .sizeMismatch {
                    discardPartialData(item)
                }
                let policy = settings.retryPolicy
                if policy.shouldRetry(error: e, retriesSoFar: item.record.retryCount) {
                    item.record.retryCount += 1
                    item.record.lastError = e
                    let delay = policy.delay(forAttempt: item.record.retryCount, retryAfter: e.retryAfter)
                    item.nextRetryAt = Date().addingTimeInterval(delay)
                    setState(item, .retrying)
                    env.store.save(item.record)
                    env.store.logEvent(downloadID: job.id, level: "info", message: "Retry \(item.record.retryCount) of \(policy.maxRetries) in \(Int(delay)) s")
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    item.nextRetryAt = nil
                    job.progress.reset(expectedLength: item.record.expectedLength, segments: item.record.segments, bytesReceived: item.record.bytesReceived)
                    setState(item, .connecting)
                    continue
                }
                fail(item, job: job, e)
                return
            }
        }
    }

    private func complete(_ item: DownloadItem, job: ActiveJob, result: EngineResult, partialURL: URL) async throws {
        absorb(job.progress.snapshot(), into: item)
        apply(result.response, to: item)
        item.record.expectedLength = item.record.expectedLength ?? result.totalBytes
        item.record.bytesReceived = result.totalBytes
        item.record.segments = result.segments
        setState(item, .verifying)
        env.store.save(item.record)

        do {
            let needHash = settings.computeSHA256 || item.record.expectedSHA256 != nil
            if needHash {
                let hash = try await Self.hash(partialURL)
                item.record.sha256 = hash
                if let expected = item.record.expectedSHA256 {
                    item.record.checksumVerified = hash == expected
                    guard hash == expected else {
                        throw DownloadError(.checksumMismatch, "The file's SHA-256 checksum does not match the expected value. The file was not saved.")
                    }
                }
            }
            if job.stopReason != nil { return }
            let root = item.record.destinationDirectory
            let directory = try env.destinations.resolvedDirectory(root: root, categoryID: item.record.categoryID, settings: settings)
            let quarantine = FileFinalizer.QuarantineInfo(sourceURL: item.record.sourceURL, pageURL: item.record.pageURL.flatMap(URL.init(string:)))
            let finalURL = try await Self.finalize(env.finalizer, partial: partialURL, directory: directory, fileName: item.record.fileName,
                                                   policy: item.record.conflictPolicy ?? settings.conflictPolicy, quarantine: quarantine)
            // Only now is the download complete.
            item.record.finalFileURL = finalURL
            item.record.fileName = finalURL.lastPathComponent
            item.record.partialFileURL = nil
            item.record.segments = []
            item.record.completedAt = Date()
            item.record.lastError = nil
            item.fileMissing = false
            finishJob(job)
            setState(item, .completed)
            env.store.save(item.record)
            env.destinations.cleanUpPartialDirectory(partialURL.deletingLastPathComponent())
            if item.record.hasStoredSecrets { env.secrets.delete(for: item.id); item.record.hasStoredSecrets = false; env.store.save(item.record) }
            sessionSecrets[item.id] = nil
            env.store.logEvent(downloadID: item.id, level: "info", message: "Completed (\(result.connectionsUsed) connection(s), \(result.totalBytes) bytes)")
            onEvent?(.completed(id: item.id, fileName: item.record.fileName, fileURL: finalURL))
            pump()
        } catch {
            if job.stopReason != nil || error is CancellationError { return }
            let e = DownloadError.from(error)
            if e.kind == .checksumMismatch { discardPartialData(item) }
            fail(item, job: job, e)
        }
    }

    @concurrent
    private static func hash(_ url: URL) async throws -> String { try IntegrityVerifier.sha256(of: url) }

    @concurrent
    private static func finalize(_ finalizer: FileFinalizer, partial: URL, directory: URL, fileName: String,
                                 policy: ConflictPolicy, quarantine: FileFinalizer.QuarantineInfo) async throws -> URL {
        try finalizer.finalize(partial: partial, directory: directory, fileName: fileName, policy: policy, quarantine: quarantine)
    }

    private func fail(_ item: DownloadItem, job: ActiveJob, _ error: DownloadError) {
        item.record.lastError = error
        if error.httpStatus != nil { item.record.httpStatus = error.httpStatus }
        finishJob(job)
        setState(item, .failed)
        if !settings.preserveIncompleteFiles || item.record.supportsRanges != true { discardPartialData(item) }
        env.store.save(item.record)
        env.store.logEvent(downloadID: item.id, level: "error", message: "Failed: \(error.description)")
        onEvent?(.failed(id: item.id, fileName: item.record.fileName, message: error.message))
        pump()
    }

    private func engineConfiguration(for record: DownloadRecord, job: ActiveJob) -> EngineConfiguration {
        var c = EngineConfiguration()
        c.maxConnections = (record.maxConnections ?? settings.maxConnectionsPerDownload).clamped(to: AppSettings.limits.connections)
        c.minimumSegmentSize = env.minimumSegmentSize
        c.connectionTimeout = settings.connectionTimeout
        c.readTimeout = settings.readTimeout
        c.checkpointInterval = env.checkpointInterval
        c.redirectPolicy = RedirectPolicy(blockPublicToPrivate: settings.blockRedirectsToPrivateNetworks)
        c.limiters = [job.limiter, globalLimiter]
        return c
    }

    // MARK: Progress

    private func startTicker() {
        ticker?.cancel()
        let interval = env.tickInterval
        ticker = Task { [weak self] in
            var counter = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self else { return }
                self.tick()
                counter += 1
                if counter % max(1, Int(1 / interval)) == 0 { self.everySecond() }
            }
        }
    }

    /// Polls engine progress a few times per second. This bounds UI updates no matter how fast data arrives.
    private func tick() {
        var total: Double = 0
        let now = ProcessInfo.processInfo.systemUptime
        for (id, job) in jobs {
            guard let item = item(id) else { continue }
            let snap = job.progress.snapshot()
            if item.record.bytesReceived != snap.bytesReceived { item.record.bytesReceived = snap.bytesReceived }
            if let expected = snap.expectedLength, item.record.expectedLength != expected { item.record.expectedLength = expected }
            if item.activeConnections != snap.activeConnections { item.activeConnections = snap.activeConnections }
            if !snap.segments.isEmpty { liveSegments[id] = snap.segments }
            if snap.response.httpStatus != nil, snap.response != job.lastResponse {
                job.lastResponse = snap.response
                apply(snap.response, to: item)
                item.record.supportsRanges = snap.response.supportsRanges ?? item.record.supportsRanges
                item.record.validators = snap.response.validators
                env.store.save(item.record)
            }
            if item.state == .connecting, snap.phase == .transferring { setState(item, .downloading) }
            if item.state == .downloading || item.state == .connecting {
                job.speed.record(totalBytes: snap.bytesReceived, at: now)
                item.currentSpeed = job.speed.currentSpeed
                item.smoothedSpeed = job.speed.smoothedSpeed
                item.eta = snap.expectedLength.flatMap { SpeedMonitor.eta(remaining: $0 - snap.bytesReceived, speed: job.speed.smoothedSpeed) }
                total += item.currentSpeed
            }
            if Date().timeIntervalSince(job.lastCheckpoint) >= env.checkpointInterval, item.state == .downloading {
                job.lastCheckpoint = Date()
                item.record.segments = snap.durableSegments
                env.store.saveProgress(id: id, bytesReceived: snap.durableBytes, segments: snap.durableSegments)
            }
        }
        if totalSpeed != total { totalSpeed = total }
    }

    private func everySecond() {
        pump()   // starts per-download scheduled items whose time arrived
        let now = Date()
        switch ScheduleEvaluator.action(schedule: settings.schedule, previousCheck: lastScheduleCheck, now: now) {
        case .start:
            env.store.logEvent(downloadID: nil, level: "info", message: "Scheduled queue start")
            startQueue()
        case .stop:
            env.store.logEvent(downloadID: nil, level: "info", message: "Scheduled queue stop")
            pauseQueue()
        case .none: break
        }
        lastScheduleCheck = now
        let cutoff = now.addingTimeInterval(-10)
        recentBrowserURLs = recentBrowserURLs.filter { $0.value > cutoff }
    }

    /// Call after the Mac wakes so a schedule boundary that passed during sleep is applied once.
    public func systemDidWake() {
        everySecond()
    }

    // MARK: Record helpers

    /// Moves a stopped download to `target` when that is legal. Completed/failed/canceled items keep
    /// their state; anything still mid-flight that cannot reach `target` (e.g. Verifying → Paused)
    /// becomes Interrupted, which can always be resumed.
    private func settle(_ item: DownloadItem, _ target: DownloadState) {
        let current = item.record.state
        guard current != target, current != .completed, current != .failed, current != .canceled || target == .canceled else { return }
        if DownloadStateMachine.canTransition(from: current, to: target) {
            setState(item, target)
        } else if DownloadStateMachine.canTransition(from: current, to: .interrupted) {
            setState(item, .interrupted)
        }
    }

    private func setState(_ item: DownloadItem, _ new: DownloadState) {
        guard item.record.state != new else { return }
        do {
            item.record.state = try DownloadStateMachine.transition(from: item.record.state, to: new)
        } catch {
            log.fault("\(String(describing: error), privacy: .public)")
            assertionFailure(String(describing: error))
        }
    }

    /// Copies durable progress and server metadata from the engine into the record.
    private func absorb(_ snap: TransferProgress.Snapshot, into item: DownloadItem) {
        item.record.segments = snap.durableSegments
        item.record.bytesReceived = snap.durableSegments.isEmpty ? (item.record.supportsRanges == true ? snap.durableBytes : snap.bytesReceived) : snap.durableBytes
        if let expected = snap.expectedLength { item.record.expectedLength = expected }
        if snap.response.httpStatus != nil {
            apply(snap.response, to: item)
            item.record.validators = snap.response.validators
            if let r = snap.response.supportsRanges { item.record.supportsRanges = r }
        }
    }

    private func apply(_ response: TransferProgress.ResponseInfo, to item: DownloadItem) {
        if let status = response.httpStatus { item.record.httpStatus = status }
        if let url = response.finalURL { item.record.finalURL = url }
        if let type = response.contentType { item.record.contentType = type }
        if !item.record.fileNameIsUserProvided, item.state != .completed {
            let name = FileNameSanitizer.suggestedName(contentDisposition: response.serverFileName.map { "attachment; filename*=UTF-8''\($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0)" },
                                                       url: response.finalURL ?? item.record.sourceURL, mimeType: response.contentType)
            if name != item.record.fileName {
                item.record.fileName = name
                item.record.categoryID = FileCategory.classify(fileName: name, categories: settings.categories)
            }
        }
    }

    private func discardPartialData(_ item: DownloadItem) {
        if let partial = item.record.partialFileURL {
            try? FileManager.default.removeItem(at: partial)
            env.destinations.cleanUpPartialDirectory(partial.deletingLastPathComponent())
        }
        item.record.partialFileURL = nil
        item.record.segments = []
        item.record.bytesReceived = 0
        item.record.validators = ResourceValidators()
        liveSegments[item.id] = nil
    }

    // MARK: Browser bridge

    /// Validates and handles one browser message (already framed) and returns the encoded reply.
    public func handleBrowserMessage(_ data: Data) -> Data {
        let reply: BrowserMessage
        switch BrowserMessageValidator.validateRequest(data, requireOrigin: true) {
        case .failure(let error):
            AppLog.browser.error("rejected browser message: \(error.description, privacy: .public)")
            reply = .error(id: nil, code: error.code, message: error.description)
        case .success(let request):
            reply = handleBrowserRequest(request)
        }
        return (try? reply.encoded()) ?? Data(#"{"v":1,"type":"error","code":"encoding"}"#.utf8)
    }

    func handleBrowserRequest(_ request: BrowserRequest) -> BrowserMessage {
        switch request {
        case .hello(let id, let browser, _):
            lastBrowserContact[(browser ?? "browser").lowercased()] = Date()
            return statusMessage(id: id)
        case .getStatus(let id):
            return statusMessage(id: id)
        case .addDownload(let r):
            lastBrowserContact[(r.browser ?? "browser").lowercased()] = Date()
            func reject(_ reason: String, _ message: String) -> BrowserMessage {
                var m = BrowserMessage(type: .downloadRejected, id: r.id)
                m.reason = reason
                m.message = message
                return m
            }
            if r.source == .interception && !settings.browserCaptureEnabled {
                return reject("captureDisabled", "Automatic capture is turned off in OleDownloadManager.")
            }
            guard let validated = try? URLValidator.validate(r.url, assumeHTTPSIfMissingScheme: false) else {
                return reject("invalidURL", "The link is not a supported http or https URL.")
            }
            let key = validated.url.absoluteString
            if let last = recentBrowserURLs[key], Date().timeIntervalSince(last) < 10 {
                return reject("duplicate", "This link was just sent.")
            }
            recentBrowserURLs[key] = Date()
            var request = NewDownloadRequest(url: validated.url)
            request.fileName = r.fileName.map { FileNameSanitizer.sanitize($0) }
            request.origin = .browser
            request.pageURL = r.pageURL
            request.referrer = r.referrer
            if let user = validated.embeddedUser { request.secrets = DownloadSecrets(user: user, password: validated.embeddedPassword) }
            switch r.mode {
            case .start: request.action = .startNow
            case .queue: request.action = .addToQueue
            case .default: request.action = settings.browserCaptureAction
            }
            switch add(request) {
            case .success(let item):
                var m = BrowserMessage(type: .downloadAccepted, id: r.id)
                m.downloadId = item.id.uuidString
                m.fileName = item.record.fileName
                return m
            case .failure(.duplicate):
                return reject("duplicate", "This link is already in OleDownloadManager.")
            case .failure(let e):
                return reject("rejected", e.description)
            }
        }
    }

    private func statusMessage(id: String?) -> BrowserMessage {
        var status = BrowserMessage(type: .status, id: id)
        status.connected = true
        status.captureEnabled = settings.browserCaptureEnabled
        status.captureAction = settings.browserCaptureAction == .startNow ? "start" : "queue"
        status.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return status
    }
}
