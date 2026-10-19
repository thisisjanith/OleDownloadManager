import Foundation
import Observation

public enum DownloadOrigin: String, Codable, Sendable {
    case user, paste, dragAndDrop, browser
    public var label: String {
        switch self {
        case .user: "Added manually"
        case .paste: "Pasted URL"
        case .dragAndDrop: "Drag and drop"
        case .browser: "Browser extension"
        }
    }
}

public enum StartMode: String, Codable, Sendable {
    /// Started explicitly ("Start Now"); runs regardless of whether the queue is running.
    case immediate
    /// Runs only while the queue is running.
    case queue
}

/// Persistent description of one download. This is what is stored in SQLite.
/// Secrets (passwords, Authorization/Cookie headers) are never part of this struct.
public struct DownloadRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var sourceURL: URL
    public var finalURL: URL?
    public var fileName: String
    public var fileNameIsUserProvided = false
    public var destinationDirectory: URL
    public var destinationVolumeUUID: String?
    public var finalFileURL: URL?
    public var partialFileURL: URL?
    public var categoryID: String
    public var state: DownloadState
    public var expectedLength: Int64?
    public var bytesReceived: Int64 = 0
    public var createdAt: Date
    public var startedAt: Date?
    public var completedAt: Date?
    public var retryCount = 0
    public var httpStatus: Int?
    public var validators = ResourceValidators()
    public var contentType: String?
    public var supportsRanges: Bool?
    public var segments: [DownloadSegment] = []
    public var lastError: DownloadError?
    public var sha256: String?
    public var expectedSHA256: String?
    public var checksumVerified: Bool?
    public var origin: DownloadOrigin = .user
    public var pageURL: String?
    public var referrer: String?
    /// Non-sensitive custom request headers only.
    public var customHeaders: [String: String] = [:]
    /// True when credentials for this download were saved to the Keychain with the user's consent.
    public var hasStoredSecrets = false
    public var conflictPolicy: ConflictPolicy?
    public var maxConnections: Int?
    public var speedLimit: Int64?
    public var startMode: StartMode = .queue
    public var queuePosition = 0
    public var scheduledAt: Date?
    public var averageSpeed: Double?
    public var trashedAt: Date?

    public init(id: UUID = UUID(), sourceURL: URL, fileName: String, destinationDirectory: URL,
                categoryID: String, state: DownloadState = .queued, createdAt: Date = Date()) {
        self.id = id
        self.sourceURL = sourceURL
        self.fileName = fileName
        self.destinationDirectory = destinationDirectory
        self.categoryID = categoryID
        self.state = state
        self.createdAt = createdAt
    }

    public var host: String { (finalURL ?? sourceURL).host ?? sourceURL.host ?? "" }

    /// Fraction 0...1, or nil when the total size is unknown.
    public var progressFraction: Double? {
        guard let total = expectedLength, total > 0 else { return expectedLength == 0 && state == .completed ? 1 : nil }
        return min(1, max(0, Double(bytesReceived) / Double(total)))
    }

    public var isTrashed: Bool { trashedAt != nil }
    public var isScheduled: Bool { (scheduledAt.map { $0 > Date() } ?? false) && state == .queued }
}

/// Observable wrapper the UI binds to. Owned and mutated only by `DownloadCoordinator` on the main actor.
@MainActor
@Observable
public final class DownloadItem: Identifiable {
    public let id: UUID
    public internal(set) var record: DownloadRecord

    // Runtime-only values, never persisted per sample.
    public internal(set) var currentSpeed: Double = 0
    public internal(set) var smoothedSpeed: Double = 0
    public internal(set) var eta: TimeInterval?
    public internal(set) var activeConnections = 0
    public internal(set) var nextRetryAt: Date?
    public internal(set) var fileMissing = false
    public internal(set) var isPausing = false
    public internal(set) var speedSamples: [Double] = []

    public init(record: DownloadRecord) {
        self.id = record.id
        self.record = record
    }

    public var state: DownloadState { record.state }
    public var fileName: String { record.fileName }
    public var host: String { record.host }
}
