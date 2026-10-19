import Foundation

public enum AddAction: String, Codable, Sendable, CaseIterable {
    case startNow, addToQueue
    public var label: String { self == .startNow ? "Start immediately" : "Add to queue" }
}

public enum ConflictPolicy: String, Codable, Sendable, CaseIterable {
    /// Keep both: the new file gets a numbered name such as "file (1).zip".
    case rename
    /// Move the existing file to the Trash, then place the new file. Requires confirmation in the UI.
    case replace
    /// Do not download when a file with the same name already exists.
    case skip
    public var label: String {
        switch self {
        case .rename: "Keep both (rename new file)"
        case .replace: "Replace (existing file goes to Trash)"
        case .skip: "Skip download"
        }
    }
}

public enum AppearancePreference: String, Codable, Sendable, CaseIterable {
    case system, light, dark
    public var label: String { rawValue.capitalized }
}

public enum ListDensity: String, Codable, Sendable, CaseIterable {
    case comfortable, compact
    public var label: String { rawValue.capitalized }
}

/// Weekly queue schedule. Times are minutes after local midnight.
public struct QueueSchedule: Codable, Sendable, Equatable {
    public var enabled: Bool = false
    public var startMinute: Int = 2 * 60
    public var stopEnabled: Bool = false
    public var stopMinute: Int = 7 * 60
    /// Calendar weekday numbers (1 = Sunday ... 7 = Saturday).
    public var weekdays: Set<Int> = Set(1...7)
    public init() {}
}

/// All persisted user preferences. Decoding tolerates missing keys so older databases keep working.
public struct AppSettings: Codable, Sendable, Equatable {
    // General
    public var defaultDirectoryPath: String?
    public var defaultDirectoryBookmark: Data?
    public var askWhereToSave = false
    public var defaultAddAction: AddAction = .startNow
    public var launchAtLogin = false
    public var showNotifications = true
    public var quitWhenLastWindowCloses = false
    public var showMenuBarItem = true
    public var resumeInterruptedOnLaunch = false
    public var startQueueOnLaunch = false

    // Downloads
    public var maxConcurrentDownloads = 3
    public var maxConnectionsPerDownload = 4
    public var maxRetries = 5
    public var conflictPolicy: ConflictPolicy = .rename
    public var organizeByCategory = false
    public var preserveIncompleteFiles = true
    public var computeSHA256 = true
    /// nil = keep partial data in a hidden folder beside the destination (same volume).
    public var customTemporaryDirectoryPath: String?
    public var categories: [FileCategory] = FileCategory.defaults

    // Network
    /// Bytes per second; 0 = unlimited.
    public var perDownloadSpeedLimit: Int64 = 0
    public var globalSpeedLimit: Int64 = 0
    public var connectionTimeout: Double = 30
    public var readTimeout: Double = 60
    public var retryBaseDelay: Double = 2
    public var retryMaxDelay: Double = 60
    public var retryBackoffMultiplier: Double = 2
    public var blockRedirectsToPrivateNetworks = true

    // Browser integration
    public var browserCaptureEnabled = true
    public var browserCaptureAction: AddAction = .startNow

    // Appearance
    public var appearance: AppearancePreference = .system
    public var listDensity: ListDensity = .comfortable

    // Scheduling
    public var schedule = QueueSchedule()

    public init() {}

    public static let limits = (
        concurrentDownloads: 1...10,
        connections: 1...8,
        retries: 0...20,
        connectionTimeout: 5.0...300.0,
        readTimeout: 5.0...600.0,
        retryBaseDelay: 0.5...120.0,
        retryMaxDelay: 1.0...3600.0,
        backoffMultiplier: 1.0...4.0
    )

    /// Returns a copy with every numeric value clamped to a safe range.
    public func validated() -> AppSettings {
        var s = self
        let l = AppSettings.limits
        s.maxConcurrentDownloads = s.maxConcurrentDownloads.clamped(to: l.concurrentDownloads)
        s.maxConnectionsPerDownload = s.maxConnectionsPerDownload.clamped(to: l.connections)
        s.maxRetries = s.maxRetries.clamped(to: l.retries)
        s.connectionTimeout = s.connectionTimeout.finiteOr(30).clamped(to: l.connectionTimeout)
        s.readTimeout = s.readTimeout.finiteOr(60).clamped(to: l.readTimeout)
        s.retryBaseDelay = s.retryBaseDelay.finiteOr(2).clamped(to: l.retryBaseDelay)
        s.retryMaxDelay = max(s.retryBaseDelay, s.retryMaxDelay.finiteOr(60).clamped(to: l.retryMaxDelay))
        s.retryBackoffMultiplier = s.retryBackoffMultiplier.finiteOr(2).clamped(to: l.backoffMultiplier)
        s.perDownloadSpeedLimit = max(0, s.perDownloadSpeedLimit)
        s.globalSpeedLimit = max(0, s.globalSpeedLimit)
        s.schedule.startMinute = s.schedule.startMinute.clamped(to: 0...1439)
        s.schedule.stopMinute = s.schedule.stopMinute.clamped(to: 0...1439)
        s.schedule.weekdays = s.schedule.weekdays.filter { (1...7).contains($0) }
        if !s.categories.contains(where: { $0.id == FileCategory.otherID }) {
            s.categories.append(FileCategory.defaults.last!)  // the defaults always end with "Other"
        }
        return s
    }

    public var retryPolicy: RetryPolicy {
        RetryPolicy(maxRetries: maxRetries, baseDelay: retryBaseDelay,
                    multiplier: retryBackoffMultiplier, maxDelay: retryMaxDelay)
    }

    // MARK: Tolerant decoding

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        defaultDirectoryPath = v(.defaultDirectoryPath, d.defaultDirectoryPath)
        defaultDirectoryBookmark = v(.defaultDirectoryBookmark, d.defaultDirectoryBookmark)
        askWhereToSave = v(.askWhereToSave, d.askWhereToSave)
        defaultAddAction = v(.defaultAddAction, d.defaultAddAction)
        launchAtLogin = v(.launchAtLogin, d.launchAtLogin)
        showNotifications = v(.showNotifications, d.showNotifications)
        quitWhenLastWindowCloses = v(.quitWhenLastWindowCloses, d.quitWhenLastWindowCloses)
        showMenuBarItem = v(.showMenuBarItem, d.showMenuBarItem)
        resumeInterruptedOnLaunch = v(.resumeInterruptedOnLaunch, d.resumeInterruptedOnLaunch)
        startQueueOnLaunch = v(.startQueueOnLaunch, d.startQueueOnLaunch)
        maxConcurrentDownloads = v(.maxConcurrentDownloads, d.maxConcurrentDownloads)
        maxConnectionsPerDownload = v(.maxConnectionsPerDownload, d.maxConnectionsPerDownload)
        maxRetries = v(.maxRetries, d.maxRetries)
        conflictPolicy = v(.conflictPolicy, d.conflictPolicy)
        organizeByCategory = v(.organizeByCategory, d.organizeByCategory)
        preserveIncompleteFiles = v(.preserveIncompleteFiles, d.preserveIncompleteFiles)
        computeSHA256 = v(.computeSHA256, d.computeSHA256)
        customTemporaryDirectoryPath = v(.customTemporaryDirectoryPath, d.customTemporaryDirectoryPath)
        categories = v(.categories, d.categories)
        perDownloadSpeedLimit = v(.perDownloadSpeedLimit, d.perDownloadSpeedLimit)
        globalSpeedLimit = v(.globalSpeedLimit, d.globalSpeedLimit)
        connectionTimeout = v(.connectionTimeout, d.connectionTimeout)
        readTimeout = v(.readTimeout, d.readTimeout)
        retryBaseDelay = v(.retryBaseDelay, d.retryBaseDelay)
        retryMaxDelay = v(.retryMaxDelay, d.retryMaxDelay)
        retryBackoffMultiplier = v(.retryBackoffMultiplier, d.retryBackoffMultiplier)
        blockRedirectsToPrivateNetworks = v(.blockRedirectsToPrivateNetworks, d.blockRedirectsToPrivateNetworks)
        browserCaptureEnabled = v(.browserCaptureEnabled, d.browserCaptureEnabled)
        browserCaptureAction = v(.browserCaptureAction, d.browserCaptureAction)
        appearance = v(.appearance, d.appearance)
        listDensity = v(.listDensity, d.listDensity)
        schedule = v(.schedule, d.schedule)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

extension Double {
    func finiteOr(_ fallback: Double) -> Double { isFinite ? self : fallback }
}
