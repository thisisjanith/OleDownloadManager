import Foundation

public struct InvalidStateTransition: Error, Equatable, CustomStringConvertible {
    public let from: DownloadState
    public let to: DownloadState
    public var description: String { "Invalid download state transition \(from.rawValue) → \(to.rawValue)" }
}

/// The single source of truth for which state changes are legal.
///
/// Every state change in the coordinator goes through `transition(from:to:)`.
/// Notably, `canceled` can only move back to `queued` (an explicit user "Restart"),
/// so a canceled download can never silently become active again.
public enum DownloadStateMachine {
    private static let table: [DownloadState: Set<DownloadState>] = [
        .queued: [.connecting, .paused, .canceled, .waitingForDestination, .failed],
        .connecting: [.downloading, .verifying, .failed, .paused, .canceled, .retrying,
                      .interrupted, .waitingForDestination, .queued],
        .downloading: [.verifying, .paused, .failed, .retrying, .interrupted, .canceled,
                       .waitingForDestination, .queued, .connecting],
        .verifying: [.completed, .failed, .canceled, .interrupted, .waitingForDestination],
        .retrying: [.connecting, .paused, .canceled, .failed, .queued, .interrupted],
        .paused: [.connecting, .queued, .canceled],
        .failed: [.queued, .connecting, .canceled],
        .interrupted: [.queued, .connecting, .paused, .canceled, .failed],
        .waitingForDestination: [.queued, .connecting, .paused, .canceled, .failed],
        .completed: [],
        .canceled: [.queued],
    ]

    public static func canTransition(from: DownloadState, to: DownloadState) -> Bool {
        table[from]?.contains(to) ?? false
    }

    @discardableResult
    public static func transition(from: DownloadState, to: DownloadState) throws -> DownloadState {
        guard canTransition(from: from, to: to) else { throw InvalidStateTransition(from: from, to: to) }
        return to
    }

    public static func allowedTargets(from: DownloadState) -> Set<DownloadState> { table[from] ?? [] }
}
