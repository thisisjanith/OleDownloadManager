import Foundation
@testable import OleDownloadCore

/// A unique temporary directory removed when the value is deinitialized.
final class TempDir: @unchecked Sendable {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("oledm-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}

func testConfig(connections: Int = 4, minSegment: Int64 = 64 * 1024) -> EngineConfiguration {
    var c = EngineConfiguration()
    c.maxConnections = connections
    c.minimumSegmentSize = minSegment
    c.connectionTimeout = 10
    c.readTimeout = 10
    c.segmentRetryBaseDelay = 0.05
    c.checkpointInterval = 0.1
    return c
}

/// Polls `condition` every 20 ms until it holds or `timeout` elapses.
func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@MainActor
func waitUntilMain(timeout: TimeInterval = 15, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
