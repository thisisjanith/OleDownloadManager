import Foundation

/// Lifecycle state of a download. Raw values are persisted in SQLite; never rename them.
public enum DownloadState: String, Codable, Sendable, CaseIterable {
    case queued
    case connecting
    case downloading
    case verifying
    case completed
    case paused
    case failed
    case retrying
    case interrupted
    case waitingForDestination
    case canceled

    /// User-facing status label.
    public var label: String {
        switch self {
        case .queued: "Waiting"
        case .connecting: "Connecting"
        case .downloading: "Downloading"
        case .verifying: "Verifying"
        case .completed: "Completed"
        case .paused: "Paused"
        case .failed: "Failed"
        case .retrying: "Retrying"
        case .interrupted: "Interrupted"
        case .waitingForDestination: "Waiting for destination"
        case .canceled: "Canceled"
        }
    }

    /// States in which a transfer task is (or should be) running.
    public var isActive: Bool {
        switch self {
        case .connecting, .downloading, .verifying, .retrying: true
        default: false
        }
    }

    /// States that are terminal for the transfer machinery.
    public var isTerminal: Bool { self == .completed || self == .canceled }

    public var canPause: Bool {
        switch self {
        case .queued, .connecting, .downloading, .retrying, .waitingForDestination: true
        default: false
        }
    }

    public var canResume: Bool {
        switch self {
        case .paused, .interrupted: true
        default: false
        }
    }

    public var canRetry: Bool { self == .failed }

    public var canCancel: Bool {
        switch self {
        case .completed, .canceled: false
        default: true
        }
    }

    public var canRestart: Bool { self == .canceled }
}
