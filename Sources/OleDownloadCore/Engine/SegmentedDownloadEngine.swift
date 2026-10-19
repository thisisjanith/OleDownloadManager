import Foundation

public struct EngineConfiguration: Sendable {
    public var maxConnections = 4
    /// Files are only split when every segment would be at least this large.
    public var minimumSegmentSize: Int64 = 1 << 20
    public var connectionTimeout: TimeInterval = 30
    public var readTimeout: TimeInterval = 60
    /// Quick in-engine retries per segment before the whole job fails (and the job-level retry policy takes over).
    public var segmentRetryLimit = 3
    public var segmentRetryBaseDelay: TimeInterval = 1
    public var checkpointInterval: TimeInterval = 2
    public var redirectPolicy = RedirectPolicy()
    public var limiters: [BandwidthLimiter] = []
    public var userAgent = "OleDownloadManager/1.0 (Macintosh; macOS)"

    public init() {}
}

/// Everything needed to resume a range-capable download from a previous run.
public struct ResumeState: Sendable, Equatable {
    public var validators: ResourceValidators
    public var expectedLength: Int64?
    public var supportsRanges: Bool?
    public var segments: [DownloadSegment]

    public init(validators: ResourceValidators, expectedLength: Int64?, supportsRanges: Bool?, segments: [DownloadSegment]) {
        self.validators = validators
        self.expectedLength = expectedLength
        self.supportsRanges = supportsRanges
        self.segments = segments
    }
}

public struct EngineJob: Sendable {
    public var url: URL
    public var headers: [String: String]
    public var credentials: BasicCredentials?
    public var partialFile: URL
    public var resume: ResumeState?

    public init(url: URL, headers: [String: String] = [:], credentials: BasicCredentials? = nil, partialFile: URL, resume: ResumeState? = nil) {
        self.url = url
        self.headers = headers
        self.credentials = credentials
        self.partialFile = partialFile
        self.resume = resume
    }
}

public struct EngineResult: Sendable {
    public var response: TransferProgress.ResponseInfo
    public var totalBytes: Int64
    public var segments: [DownloadSegment]
    public var connectionsUsed: Int
    /// True when the run continued from previously saved data.
    public var resumed: Bool
}

/// Abstraction over the transfer engine so the coordinator can be tested with a fake.
public protocol DownloadEngine: Sendable {
    func download(_ job: EngineJob, configuration: EngineConfiguration, progress: TransferProgress) async throws -> EngineResult
}

/// HTTP/HTTPS engine handling single-connection and segmented (multi-connection) transfers.
///
/// Data is written at explicit offsets into one partial file; each connection may only write inside
/// its own byte range. Segment progress is checkpointed (after fsync) so a later run can resume.
public struct HTTPDownloadEngine: DownloadEngine {
    public init() {}

    public func download(_ job: EngineJob, configuration: EngineConfiguration, progress: TransferProgress) async throws -> EngineResult {
        let run = EngineRun(job: job, config: configuration, progress: progress)
        return try await run.execute()
    }
}

private enum SegmentOutcome: Sendable {
    case completed(Int)
    case failed(Int, Error)
}

private struct ResumeNotPossible: Error {}

final class EngineRun: @unchecked Sendable {
    let job: EngineJob
    let config: EngineConfiguration
    let progress: TransferProgress
    let session: TransferSession
    private let fileLock = NSLock()
    private var _file: PartialFile?
    private let log = AppLog.engine

    init(job: EngineJob, config: EngineConfiguration, progress: TransferProgress) {
        self.job = job
        self.config = config
        self.progress = progress
        session = TransferSession(originalURL: job.url, credentials: job.credentials, redirectPolicy: config.redirectPolicy,
                                  readTimeout: config.readTimeout, maxConnectionsPerHost: config.maxConnections + 1,
                                  limiters: config.limiters)
    }

    private var file: PartialFile? { fileLock.withLock { _file } }

    private func openFile(truncate: Bool) throws -> PartialFile {
        let new = try PartialFile(url: job.partialFile, truncate: truncate)
        let old = fileLock.withLock { () -> PartialFile? in
            let o = _file
            _file = new
            return o
        }
        old?.closeFile()
        return new
    }

    func execute() async throws -> EngineResult {
        let interval = config.checkpointInterval
        let checkpoint = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                let captured = self.progress.captureForCheckpoint()
                self.file?.sync()
                self.progress.markDurable(captured)
            }
        }
        defer { checkpoint.cancel() }
        do {
            let result = try await perform()
            await shutDown()
            return result
        } catch {
            await shutDown()
            throw error
        }
    }

    /// Stops all connections, waits for in-flight delegate callbacks, then fsyncs and closes the file.
    /// Only after this is the final progress published as durable, so a pause never persists more
    /// bytes than are actually on disk.
    private func shutDown() async {
        await session.invalidateAndWait()
        file?.closeFile()
        progress.markDurable(progress.captureForCheckpoint())
    }

    // MARK: Strategy

    private func perform() async throws -> EngineResult {
        var allowResume = job.resume != nil
        var restartsAfterChange = 0
        var singleStreamOnly = false
        while true {
            try Task.checkCancellation()
            do {
                if allowResume, let resume = job.resume {
                    do {
                        return try await resumeSegmented(resume)
                    } catch is ResumeNotPossible {
                        log.info("saved progress cannot be reused; restarting from the beginning")
                        allowResume = false
                        continue
                    }
                }
                return try await freshStart(singleStreamOnly: singleStreamOnly)
            } catch let e as DownloadError where e.kind == .sourceChanged && (restartsAfterChange < 1 || !singleStreamOnly) {
                // First change: restart cleanly. If the validators keep changing, segments can never be
                // proven to belong together, so continue with one plain connection that doesn't need them.
                if restartsAfterChange >= 1 { singleStreamOnly = true }
                log.info("source changed on the server; restarting from the beginning")
                restartsAfterChange += 1
                allowResume = false
            } catch let e as DownloadError where e.kind == .invalidRangeResponse && !singleStreamOnly {
                log.info("range requests unreliable; falling back to a single connection")
                singleStreamOnly = true
                allowResume = false
            }
        }
    }

    private func freshStart(singleStreamOnly: Bool) async throws -> EngineResult {
        let file = try openFile(truncate: true)
        progress.reset(expectedLength: nil, segments: [], bytesReceived: 0)
        progress.setPhase(.connecting)

        let primary = session.makeTransfer(makeRequest(job.url, range: singleStreamOnly ? nil : "bytes=0-"))
        let response = try await primary.response(timeout: config.connectionTimeout)
        let status = response.statusCode
        let encoded = hasContentEncoding(response)

        var info = TransferProgress.ResponseInfo()
        info.finalURL = response.url
        info.httpStatus = status
        info.contentType = response.mimeType
        info.serverFileName = ContentDisposition.fileName(from: response.value(forHTTPHeaderField: "Content-Disposition"))

        var total: Int64?
        var rangeConfirmed = false
        switch status {
        case 206:
            guard let cr = ContentRange.parse(response.value(forHTTPHeaderField: "Content-Range")),
                  cr.first == 0, let complete = cr.completeLength, cr.last == complete - 1, !encoded else {
                primary.reject()
                throw DownloadError(.invalidRangeResponse, "The server returned an inconsistent byte range.")
            }
            total = complete
            rangeConfirmed = true
        case 200:
            let length = response.expectedContentLength
            total = (length >= 0 && !encoded) ? length : nil
        default:
            primary.reject()
            throw httpError(response)
        }
        info.validators = ResourceValidators(response: response, contentLength: total)

        if total == 0 {
            primary.reject()
            info.supportsRanges = rangeConfirmed
            progress.setResponse(info)
            progress.setSegments([], expectedLength: 0)
            return try finish(info: info, connections: 1, resumed: false)
        }

        // Decide whether to split. A 206 to "bytes=0-" proves range support; a 200 is double-checked
        // with a one-byte probe because Accept-Ranges alone is not trustworthy.
        if !singleStreamOnly, let total, !rangeConfirmed, !encoded {
            rangeConfirmed = await probeRangeSupport(url: response.url ?? job.url, total: total, validators: info.validators)
        }
        info.supportsRanges = singleStreamOnly ? false : rangeConfirmed
        progress.setResponse(info)

        var connections = 1
        if let total, rangeConfirmed, segmentationAllowed(finalURL: response.url) {
            connections = SegmentPlanner.connectionCount(totalLength: total, maxConnections: config.maxConnections,
                                                         minimumSegmentSize: config.minimumSegmentSize)
        }

        if let total, rangeConfirmed {
            let segments = SegmentPlanner.plan(totalLength: total, count: connections)
            progress.setSegments(segments, expectedLength: total)
            let writer = RangeWriter(file: file, progress: progress, segmentIndex: 0, start: 0, end: segments[0].end)
            primary.accept(into: writer)
            progress.setPhase(.transferring)
            try await runSegments(primary: (primary, 0), url: response.url ?? job.url, total: total, validators: info.validators)
        } else {
            progress.setSegments([], expectedLength: total)
            let writer = RangeWriter(file: file, progress: progress, segmentIndex: nil, start: 0, end: total.map { $0 - 1 })
            progress.connectionOpened()
            defer { progress.connectionClosed() }
            primary.accept(into: writer)
            progress.setPhase(.transferring)
            try await primary.completion()
            if let total, writer.written != total {
                throw DownloadError(.connectionLost, "The connection closed after \(writer.written) of \(total) bytes.")
            }
        }
        return try finish(info: info, connections: connections, resumed: false)
    }

    private func resumeSegmented(_ resume: ResumeState) async throws -> EngineResult {
        guard resume.supportsRanges == true, let total = resume.expectedLength, total > 0,
              SegmentPlanner.isValidTiling(resume.segments, totalLength: total),
              FileManager.default.fileExists(atPath: job.partialFile.path) else { throw ResumeNotPossible() }
        let file = try openFile(truncate: false)
        // Every byte we claim to have must physically exist in the file.
        let highestWritten = resume.segments.filter { $0.completed > 0 }.map { $0.start + $0.completed }.max() ?? 0
        guard file.size >= highestWritten else { throw ResumeNotPossible() }

        let segments = resume.segments.sorted { $0.index < $1.index }
        progress.reset(expectedLength: total, segments: segments, bytesReceived: segments.reduce(0) { $0 + $1.completed })
        var info = TransferProgress.ResponseInfo()
        info.validators = resume.validators
        info.supportsRanges = true
        progress.setResponse(info)
        progress.setPhase(.connecting)

        guard let first = segments.first(where: { !$0.isComplete }) else {
            return try finish(info: info, connections: 0, resumed: true)
        }
        // The first request goes to the original URL (following redirects again, in case a signed
        // mirror URL expired) and must prove the server still has the same representation.
        let offset = first.nextOffset
        let transfer = session.makeTransfer(makeRequest(job.url, range: "bytes=\(offset)-\(first.end)", ifRange: resume.validators.ifRangeValue))
        let response = try await transfer.response(timeout: config.connectionTimeout)
        let cr = try validateRangeResponse(response, transfer: transfer, offset: offset, end: first.end, total: total, validators: resume.validators)
        info.finalURL = response.url
        info.httpStatus = response.statusCode
        info.contentType = response.mimeType
        info.serverFileName = ContentDisposition.fileName(from: response.value(forHTTPHeaderField: "Content-Disposition"))
        let fresh = ResourceValidators(response: response, contentLength: total)
        info.validators = ResourceValidators(etag: resume.validators.etag ?? fresh.etag,
                                             lastModified: resume.validators.lastModified ?? fresh.lastModified,
                                             contentLength: total)
        progress.setResponse(info)
        let writer = RangeWriter(file: file, progress: progress, segmentIndex: first.index, start: offset, end: min(cr.last, first.end))
        transfer.accept(into: writer)
        progress.setPhase(.transferring)
        let connections = min(config.maxConnections, segments.filter { !$0.isComplete }.count)
        try await runSegments(primary: (transfer, first.index), url: response.url ?? job.url, total: total, validators: info.validators)
        return try finish(info: info, connections: max(1, connections), resumed: true)
    }

    // MARK: Segment pool

    private func runSegments(primary: (DataTransfer, Int)?, url: URL, total: Int64, validators: ResourceValidators) async throws {
        let all = progress.currentSegments
        var pending = all.filter { !$0.isComplete && $0.index != primary?.1 }.map(\.index)
        var limit = max(1, min(config.maxConnections, pending.count + (primary == nil ? 0 : 1)))
        var attempts: [Int: Int] = [:]
        var delays: [Int: TimeInterval] = [:]

        try await withThrowingTaskGroup(of: SegmentOutcome.self) { group in
            var running = 0
            if let (transfer, index) = primary {
                running += 1
                group.addTask {
                    do {
                        self.progress.connectionOpened()
                        defer { self.progress.connectionClosed() }
                        try await transfer.completion()
                        try await self.runSegment(index, url: url, total: total, validators: validators, delay: 0)
                        return .completed(index)
                    } catch {
                        return .failed(index, error)
                    }
                }
            }
            func launch() {
                while running < limit, !pending.isEmpty {
                    let index = pending.removeFirst()
                    let delay = delays[index] ?? 0
                    running += 1
                    group.addTask {
                        do {
                            try await self.runSegment(index, url: url, total: total, validators: validators, delay: delay)
                            return .completed(index)
                        } catch {
                            return .failed(index, error)
                        }
                    }
                }
            }
            launch()
            while let outcome = try await group.next() {
                running -= 1
                if case .failed(let index, let error) = outcome {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    let e = DownloadError.from(error)
                    let attempt = (attempts[index] ?? 0) + 1
                    attempts[index] = attempt
                    if (e.kind == .rateLimited || e.httpStatus == 503) && limit > 1 && attempt <= config.segmentRetryLimit + 2 {
                        // The server pushes back on parallel connections: use fewer of them.
                        limit -= 1
                        log.info("server throttled parallel connections; reducing to \(limit)")
                        delays[index] = e.retryAfter.map { min($0, 30) } ?? config.segmentRetryBaseDelay
                        pending.append(index)
                    } else if e.isTransient && attempt <= config.segmentRetryLimit {
                        delays[index] = config.segmentRetryBaseDelay * pow(2, Double(attempt - 1))
                        pending.append(index)
                    } else {
                        throw e
                    }
                }
                launch()
            }
        }
        guard progress.currentSegments.allSatisfy(\.isComplete) else {
            throw DownloadError(.sizeMismatch, "Some parts of the file were not downloaded.")
        }
    }

    /// Downloads whatever remains of segment `index`, issuing range requests until it is complete.
    private func runSegment(_ index: Int, url: URL, total: Int64, validators: ResourceValidators, delay: TimeInterval) async throws {
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        guard let file else { throw CancellationError() }
        while let segment = progress.segment(index), !segment.isComplete {
            try Task.checkCancellation()
            let offset = segment.nextOffset
            let transfer = session.makeTransfer(makeRequest(url, range: "bytes=\(offset)-\(segment.end)", ifRange: validators.ifRangeValue))
            let response = try await transfer.response(timeout: config.connectionTimeout)
            let cr = try validateRangeResponse(response, transfer: transfer, offset: offset, end: segment.end, total: total, validators: validators)
            let writer = RangeWriter(file: file, progress: progress, segmentIndex: index, start: offset, end: min(cr.last, segment.end))
            progress.connectionOpened()
            defer { progress.connectionClosed() }
            transfer.accept(into: writer)
            try await transfer.completion()
            if writer.written == 0 {
                throw DownloadError(.invalidResponse, "The server sent an empty range response.")
            }
        }
    }

    /// Accepts only a 206 whose Content-Range starts exactly at `offset`, ends within the segment and
    /// reports the same total size and validators. Everything else is rejected before any byte is written.
    private func validateRangeResponse(_ response: HTTPURLResponse, transfer: DataTransfer, offset: Int64, end: Int64,
                                       total: Int64, validators: ResourceValidators) throws -> ContentRange {
        let status = response.statusCode
        let fresh = ResourceValidators(response: response, contentLength: nil)
        switch status {
        case 206:
            guard let cr = ContentRange.parse(response.value(forHTTPHeaderField: "Content-Range")) else {
                transfer.reject()
                throw DownloadError(.invalidRangeResponse, "The server sent a partial response without a valid Content-Range header.")
            }
            if let complete = cr.completeLength, complete != total {
                transfer.reject()
                throw DownloadError(.sourceChanged, "The file size on the server changed from \(total) to \(complete) bytes.")
            }
            if fresh.conflicts(with: validators) {
                transfer.reject()
                throw DownloadError(.sourceChanged, "The file on the server changed during the download.")
            }
            guard cr.first == offset, cr.last <= end, cr.completeLength != nil, !hasContentEncoding(response) else {
                transfer.reject()
                throw DownloadError(.invalidRangeResponse, "The server returned bytes \(cr.first)-\(cr.last) instead of \(offset)-\(end).")
            }
            return cr
        case 200:
            transfer.reject()
            let length = response.expectedContentLength
            let full = ResourceValidators(response: response, contentLength: length >= 0 ? length : nil)
            if full.conflicts(with: ResourceValidators(etag: validators.etag, lastModified: validators.lastModified, contentLength: total)) {
                throw DownloadError(.sourceChanged, "The file on the server changed since the download started.")
            }
            throw DownloadError(.invalidRangeResponse, "The server ignored the byte-range request.")
        case 416:
            transfer.reject()
            throw DownloadError(.invalidRangeResponse, "The server rejected the requested byte range (HTTP 416).")
        default:
            transfer.reject()
            throw httpError(response)
        }
    }

    private func probeRangeSupport(url: URL, total: Int64, validators: ResourceValidators) async -> Bool {
        guard total > 1 else { return false }
        let last = total - 1
        let probe = session.makeTransfer(makeRequest(url, range: "bytes=\(last)-\(last)"))
        defer { probe.cancel() }
        guard let response = try? await probe.response(timeout: config.connectionTimeout) else { return false }
        probe.reject()
        guard response.statusCode == 206,
              let cr = ContentRange.parse(response.value(forHTTPHeaderField: "Content-Range")),
              cr.first == last, cr.last == last, cr.completeLength == total else { return false }
        return !ResourceValidators(response: response, contentLength: total).conflicts(with: validators)
    }

    // MARK: Helpers

    private func finish(info: TransferProgress.ResponseInfo, connections: Int, resumed: Bool) throws -> EngineResult {
        progress.setPhase(.finishing)
        guard let file else { throw CancellationError() }
        file.sync()
        let size = file.size
        let snapshot = progress.snapshot()
        if let expected = snapshot.expectedLength {
            guard size == expected else {
                throw DownloadError(.sizeMismatch, "The downloaded file is \(size) bytes but the server announced \(expected) bytes.")
            }
            if !snapshot.segments.isEmpty {
                let sum = snapshot.segments.reduce(Int64(0)) { $0 + $1.completed }
                guard snapshot.segments.allSatisfy(\.isComplete), sum == expected else {
                    throw DownloadError(.sizeMismatch, "Not all parts of the file were downloaded.")
                }
            }
        }
        return EngineResult(response: info, totalBytes: size, segments: snapshot.segments, connectionsUsed: connections, resumed: resumed)
    }

    private func segmentationAllowed(finalURL: URL?) -> Bool {
        let hasAuth = job.credentials != nil || job.headers.keys.contains { Redactor.isSensitiveHeader($0) }
        guard hasAuth else { return true }
        // Don't fan authenticated requests out to a host the user didn't authorize.
        return finalURL?.host?.lowercased() == job.url.host?.lowercased()
    }

    private func hasContentEncoding(_ response: HTTPURLResponse) -> Bool {
        guard let value = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased() else { return false }
        return !value.isEmpty && value != "identity"
    }

    private func httpError(_ response: HTTPURLResponse) -> DownloadError {
        let retryAfter = RetryPolicy.parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"))
        if (300..<400).contains(response.statusCode) {
            return DownloadError(.unsafeRedirect, "The server redirected to a location that could not be followed (HTTP \(response.statusCode)).", httpStatus: response.statusCode)
        }
        if (200..<300).contains(response.statusCode) {
            return DownloadError(.invalidResponse, "The server responded with HTTP \(response.statusCode) and no file.", httpStatus: response.statusCode)
        }
        return DownloadError.http(status: response.statusCode, retryAfter: retryAfter)
    }

    func makeRequest(_ url: URL, range: String?, ifRange: String? = nil) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: config.readTimeout)
        request.httpShouldHandleCookies = false
        for (name, value) in job.headers where (try? HTTPHeaderValidator.validate(name: name, value: value)) != nil {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // Byte ranges refer to the encoded representation, so ask for the file as-is.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        }
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        if let ifRange { request.setValue(ifRange, forHTTPHeaderField: "If-Range") }
        return request
    }
}
