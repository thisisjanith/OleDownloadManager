import Testing
@testable import OleDownloadCore

@Suite("Download state machine")
struct StateMachineTests {
    @Test func happyPath() throws {
        var s = DownloadState.queued
        for next in [DownloadState.connecting, .downloading, .verifying, .completed] {
            s = try DownloadStateMachine.transition(from: s, to: next)
        }
        #expect(s == .completed)
    }

    @Test(arguments: [
        (DownloadState.downloading, DownloadState.paused),
        (.downloading, .failed),
        (.downloading, .interrupted),
        (.failed, .queued),
        (.failed, .connecting),
        (.paused, .connecting),
        (.paused, .queued),
        (.retrying, .connecting),
        (.waitingForDestination, .queued),
        (.canceled, .queued),
    ])
    func validTransitions(from: DownloadState, to: DownloadState) {
        #expect(DownloadStateMachine.canTransition(from: from, to: to))
    }

    @Test(arguments: [
        (DownloadState.canceled, DownloadState.connecting),
        (.canceled, .downloading),
        (.canceled, .retrying),
        (.completed, .queued),
        (.completed, .downloading),
        (.queued, .completed),
        (.paused, .completed),
        (.failed, .downloading),
        (.verifying, .downloading),
    ])
    func invalidTransitions(from: DownloadState, to: DownloadState) {
        #expect(!DownloadStateMachine.canTransition(from: from, to: to))
        #expect(throws: InvalidStateTransition(from: from, to: to)) {
            try DownloadStateMachine.transition(from: from, to: to)
        }
    }

    @Test func completedIsTerminal() {
        #expect(DownloadStateMachine.allowedTargets(from: .completed).isEmpty)
    }

    @Test func canceledOnlyRestartsThroughQueue() {
        #expect(DownloadStateMachine.allowedTargets(from: .canceled) == [.queued])
    }

    @Test func everyStateHasAnEntry() {
        for state in DownloadState.allCases where state != .completed {
            #expect(!DownloadStateMachine.allowedTargets(from: state).isEmpty, "\(state) has no exits")
        }
    }
}
