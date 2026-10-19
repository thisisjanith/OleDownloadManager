import Foundation

/// Live, thread-safe progress of one engine run. Writers (URLSession delegate queue) update it per
/// chunk; the coordinator polls `snapshot()` a few times per second, which naturally throttles UI updates.
public final class TransferProgress: @unchecked Sendable {
    public enum Phase: String, Sendable { case connecting, transferring, finishing }

    public struct ResponseInfo: Sendable, Equatable {
        public var finalURL: URL?
        public var httpStatus: Int?
        public var validators = ResourceValidators()
        public var contentType: String?
        public var serverFileName: String?
        public var supportsRanges: Bool?
    }

    public struct Snapshot: Sendable {
        public var phase: Phase
        public var bytesReceived: Int64
        public var expectedLength: Int64?
        public var segments: [DownloadSegment]
        /// State known to be flushed to disk (fsync'ed). This is what gets persisted.
        public var durableSegments: [DownloadSegment]
        public var durableBytes: Int64
        public var activeConnections: Int
        public var response: ResponseInfo
    }

    private let lock = NSLock()
    private var phase: Phase = .connecting
    private var bytes: Int64 = 0
    private var expected: Int64?
    private var segments: [DownloadSegment] = []
    private var durableSegments: [DownloadSegment] = []
    private var durableBytes: Int64 = 0
    private var connections = 0
    private var response = ResponseInfo()

    public init() {}

    public func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(phase: phase, bytesReceived: bytes, expectedLength: expected, segments: segments,
                     durableSegments: durableSegments, durableBytes: durableBytes,
                     activeConnections: connections, response: response)
        }
    }

    func reset(expectedLength: Int64?, segments: [DownloadSegment], bytesReceived: Int64) {
        lock.withLock {
            expected = expectedLength
            self.segments = segments
            bytes = bytesReceived
            durableSegments = segments
            durableBytes = bytesReceived
        }
    }

    func setSegments(_ s: [DownloadSegment], expectedLength: Int64?) {
        lock.withLock {
            segments = s
            expected = expectedLength
            bytes = s.isEmpty ? bytes : s.reduce(0) { $0 + $1.completed }
        }
    }

    func setPhase(_ p: Phase) { lock.withLock { phase = p } }
    func setResponse(_ r: ResponseInfo) { lock.withLock { response = r } }
    func updateResponse(_ body: (inout ResponseInfo) -> Void) { lock.withLock { body(&response) } }
    func connectionOpened() { lock.withLock { connections += 1 } }
    func connectionClosed() { lock.withLock { connections = max(0, connections - 1) } }

    func add(_ count: Int, segment: Int?) {
        lock.withLock {
            bytes += Int64(count)
            if let segment, segments.indices.contains(segment) { segments[segment].completed += Int64(count) }
        }
    }

    func segment(_ index: Int) -> DownloadSegment? { lock.withLock { segments.indices.contains(index) ? segments[index] : nil } }
    var currentSegments: [DownloadSegment] { lock.withLock { segments } }
    var currentBytes: Int64 { lock.withLock { bytes } }

    /// Captures counters, then (after the caller fsyncs) publishes them as durable. Bytes counted
    /// before the fsync were already written with pwrite, so the fsync covers them.
    func captureForCheckpoint() -> (segments: [DownloadSegment], bytes: Int64) { lock.withLock { (segments, bytes) } }

    func markDurable(_ captured: (segments: [DownloadSegment], bytes: Int64)) {
        lock.withLock {
            durableSegments = captured.segments
            durableBytes = captured.bytes
        }
    }
}

/// The partial file. All writes go through `pwrite` at explicit offsets, guarded by a lock so a write
/// can never race with `close` (which would otherwise risk writing into a reused descriptor).
final class PartialFile: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    let url: URL

    init(url: URL, truncate: Bool) throws {
        self.url = url
        let flags = O_RDWR | O_CREAT | (truncate ? O_TRUNC : 0)
        let fd = open(url.path, flags, 0o644)
        guard fd >= 0 else { throw DownloadError.from(posix: errno, detail: "open partial file") }
        self.fd = fd
    }

    deinit { if fd >= 0 { close(fd) } }

    func write(_ data: Data, at offset: Int64) throws {
        try lock.withLock {
            guard fd >= 0 else { throw CancellationError() }
            var written = 0
            try data.withUnsafeBytes { buf in
                guard let base = buf.baseAddress else { return }
                while written < buf.count {
                    let n = pwrite(fd, base.advanced(by: written), buf.count - written, off_t(offset + Int64(written)))
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw DownloadError.from(posix: errno, detail: "write partial file")
                    }
                    written += n
                }
            }
        }
    }

    func truncate(to length: Int64) throws {
        try lock.withLock {
            guard fd >= 0, ftruncate(fd, off_t(length)) == 0 else { throw DownloadError.from(posix: errno, detail: "truncate") }
        }
    }

    var size: Int64 {
        lock.withLock {
            var st = stat()
            return fd >= 0 && fstat(fd, &st) == 0 ? Int64(st.st_size) : 0
        }
    }

    func sync() { lock.withLock { if fd >= 0 { _ = fsync(fd) } } }

    func closeFile() {
        lock.withLock {
            if fd >= 0 {
                _ = fsync(fd)
                close(fd)
                fd = -1
            }
        }
    }
}

/// Writes one response body into `[start, end]` of the partial file and never outside it.
final class RangeWriter: @unchecked Sendable {
    private let file: PartialFile
    private let progress: TransferProgress
    private let segmentIndex: Int?
    private let end: Int64?
    private(set) var offset: Int64
    private(set) var written: Int64 = 0

    init(file: PartialFile, progress: TransferProgress, segmentIndex: Int?, start: Int64, end: Int64?) {
        self.file = file
        self.progress = progress
        self.segmentIndex = segmentIndex
        self.offset = start
        self.end = end
    }

    /// Returns true when the assigned range has been filled and the connection should stop.
    func write(_ data: Data) throws -> Bool {
        var chunk = data
        var reachedEnd = false
        if let end {
            let allowed = end - offset + 1
            if allowed <= 0 { return true }
            if Int64(chunk.count) >= allowed {
                chunk = chunk.prefix(Int(allowed))
                reachedEnd = true
            }
        }
        guard !chunk.isEmpty else { return reachedEnd }
        try file.write(chunk, at: offset)
        offset += Int64(chunk.count)
        written += Int64(chunk.count)
        progress.add(chunk.count, segment: segmentIndex)
        return reachedEnd
    }
}
