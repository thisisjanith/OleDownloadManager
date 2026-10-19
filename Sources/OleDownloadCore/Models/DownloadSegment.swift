import Foundation

/// A contiguous, inclusive byte range assigned to one connection.
public struct DownloadSegment: Codable, Sendable, Equatable, Identifiable {
    /// Stable identity within its download (0-based, ordered by `start`).
    public var index: Int
    /// First byte offset (inclusive).
    public var start: Int64
    /// Last byte offset (inclusive).
    public var end: Int64
    /// Bytes of this range already written to the partial file, counted from `start`.
    public var completed: Int64

    public var id: Int { index }
    public var length: Int64 { end - start + 1 }
    public var isComplete: Bool { completed >= length }
    public var nextOffset: Int64 { start + completed }
    public var remaining: Int64 { max(0, length - completed) }

    public init(index: Int, start: Int64, end: Int64, completed: Int64 = 0) {
        self.index = index
        self.start = start
        self.end = end
        self.completed = completed
    }
}

public enum SegmentPlanner {
    /// Splits `[0, totalLength)` into `count` contiguous, non-overlapping inclusive ranges.
    /// The remainder bytes are spread one each over the first segments, so lengths differ by at most 1.
    public static func plan(totalLength: Int64, count: Int) -> [DownloadSegment] {
        guard totalLength > 0 else { return [] }
        let n = Int64(max(1, min(Int64(count), totalLength)))
        let base = totalLength / n
        let remainder = totalLength % n
        var segments: [DownloadSegment] = []
        segments.reserveCapacity(Int(n))
        var offset: Int64 = 0
        for i in 0..<n {
            let len = base + (i < remainder ? 1 : 0)
            segments.append(DownloadSegment(index: Int(i), start: offset, end: offset + len - 1))
            offset += len
        }
        return segments
    }

    /// Number of connections worth using for a file of `totalLength` bytes.
    public static func connectionCount(totalLength: Int64, maxConnections: Int, minimumSegmentSize: Int64) -> Int {
        guard totalLength > 0, maxConnections > 1, minimumSegmentSize > 0 else { return 1 }
        let bySize = totalLength / minimumSegmentSize
        return Int(max(1, min(Int64(maxConnections), bySize)))
    }

    /// Validates that segments exactly tile `[0, totalLength)` with no gaps or overlaps
    /// and that progress counters are within bounds.
    public static func isValidTiling(_ segments: [DownloadSegment], totalLength: Int64) -> Bool {
        guard !segments.isEmpty else { return totalLength == 0 }
        let sorted = segments.sorted { $0.start < $1.start }
        var expectedStart: Int64 = 0
        for s in sorted {
            guard s.start == expectedStart, s.end >= s.start, s.completed >= 0, s.completed <= s.length else { return false }
            expectedStart = s.end + 1
        }
        return expectedStart == totalLength
    }
}
