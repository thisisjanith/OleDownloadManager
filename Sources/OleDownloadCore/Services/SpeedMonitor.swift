import Foundation

/// Rolling-window transfer speed with exponential smoothing for display and ETA.
/// Uses only differences inside the window, so a long download's average does not hide a slowdown.
public struct SpeedMonitor: Sendable {
    public let window: TimeInterval
    private var samples: [(time: TimeInterval, bytes: Int64)] = []
    private var ema: Double?
    private let alpha: Double

    public init(window: TimeInterval = 5, smoothing alpha: Double = 0.3) {
        self.window = max(0.5, window)
        self.alpha = min(max(alpha, 0.01), 1)
    }

    public mutating func reset() {
        samples.removeAll()
        ema = nil
    }

    public mutating func record(totalBytes: Int64, at time: TimeInterval) {
        if let last = samples.last, totalBytes < last.bytes || time < last.time {
            reset()   // the counter went backwards (restart) or the clock jumped
        }
        samples.append((time, totalBytes))
        while let first = samples.first, time - first.time > window, samples.count > 2 { samples.removeFirst() }
        let speed = currentSpeed
        ema = ema.map { alpha * speed + (1 - alpha) * $0 } ?? speed
    }

    /// Bytes per second over the rolling window.
    public var currentSpeed: Double {
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return 0 }
        let delta = Double(last.bytes) - Double(first.bytes)
        let v = delta / (last.time - first.time)
        return v.isFinite && v > 0 ? v : 0
    }

    public var smoothedSpeed: Double {
        let v = ema ?? 0
        return v.isFinite && v > 0 ? v : 0
    }

    /// Remaining time, or nil when it cannot be estimated reliably.
    public static func eta(remaining: Int64, speed: Double) -> TimeInterval? {
        guard remaining >= 0, speed.isFinite, speed > 1 else { return nil }
        let t = Double(remaining) / speed
        return t.isFinite && t < 365 * 24 * 3600 ? t : nil
    }
}
