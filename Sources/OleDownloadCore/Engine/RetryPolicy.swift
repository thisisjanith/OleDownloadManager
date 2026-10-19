import Foundation

/// Exponential backoff with jitter. Pure value type so it is trivially testable.
public struct RetryPolicy: Sendable, Equatable {
    public var maxRetries: Int
    public var baseDelay: TimeInterval
    public var multiplier: Double
    public var maxDelay: TimeInterval
    /// Fraction of the computed delay that is randomized, e.g. 0.2 = ±20 %.
    public var jitter: Double
    /// Upper bound for honoring a server's Retry-After header.
    public var maxRetryAfter: TimeInterval

    public init(maxRetries: Int = 5, baseDelay: TimeInterval = 2, multiplier: Double = 2,
                maxDelay: TimeInterval = 60, jitter: Double = 0.2, maxRetryAfter: TimeInterval = 600) {
        self.maxRetries = max(0, maxRetries)
        self.baseDelay = max(0, baseDelay)
        self.multiplier = max(1, multiplier)
        self.maxDelay = max(0, maxDelay)
        self.jitter = min(max(0, jitter), 1)
        self.maxRetryAfter = max(0, maxRetryAfter)
    }

    /// Whether another automatic attempt is allowed after `retriesSoFar` automatic retries.
    public func shouldRetry(error: DownloadError, retriesSoFar: Int) -> Bool {
        error.isTransient && retriesSoFar < maxRetries
    }

    /// Delay before automatic retry number `attempt` (1-based).
    /// - Parameter random: returns a value in 0...1; injectable for deterministic tests.
    public func delay(forAttempt attempt: Int, retryAfter: TimeInterval? = nil,
                      random: () -> Double = { Double.random(in: 0...1) }) -> TimeInterval {
        if let retryAfter, retryAfter.isFinite, retryAfter >= 0 {
            return min(retryAfter, maxRetryAfter)
        }
        let exponent = Double(max(0, attempt - 1))
        // Guard against overflow for large attempt numbers.
        let raw = baseDelay * pow(multiplier, min(exponent, 64))
        let capped = min(raw.isFinite ? raw : maxDelay, maxDelay)
        let spread = capped * jitter
        let jittered = capped - spread + (2 * spread * min(max(random(), 0), 1))
        return max(0, jittered)
    }

    /// Parses an HTTP Retry-After header (delta-seconds or HTTP-date).
    public static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Int(value) { return seconds >= 0 ? TimeInterval(seconds) : nil }
        guard let date = HTTPDate.parse(value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

enum HTTPDate {
    static func parse(_ string: String) -> Date? {
        let formats = ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"]
        for format in formats {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "GMT")
            f.dateFormat = format
            if let d = f.date(from: string) { return d }
        }
        return nil
    }
}
