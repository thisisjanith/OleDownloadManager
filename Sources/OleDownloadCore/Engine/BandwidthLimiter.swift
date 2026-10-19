import Foundation

/// Token-bucket rate limiter shared by every connection it governs.
/// `consume` returns how long the caller should pause; the transport suspends the URLSession task
/// for that long, which lets TCP flow control slow the sender down.
public final class BandwidthLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var rate: Int64
    private var tokens: Double
    private var last: TimeInterval

    /// - Parameter bytesPerSecond: 0 or less means unlimited.
    public init(bytesPerSecond: Int64) {
        rate = bytesPerSecond
        tokens = Double(max(0, bytesPerSecond))
        last = ProcessInfo.processInfo.systemUptime
    }

    public var bytesPerSecond: Int64 { lock.withLock { rate } }

    public func setRate(_ bytesPerSecond: Int64) {
        lock.withLock {
            rate = bytesPerSecond
            tokens = min(tokens, Double(max(0, bytesPerSecond)))
        }
    }

    public func consume(_ bytes: Int, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        lock.withLock {
            guard rate > 0 else { return 0 }
            let r = Double(rate)
            let elapsed = max(0, now - last)
            last = now
            tokens = min(r, tokens + elapsed * r)   // at most one second of burst
            tokens -= Double(bytes)
            return tokens >= 0 ? 0 : min(5, -tokens / r)
        }
    }
}
