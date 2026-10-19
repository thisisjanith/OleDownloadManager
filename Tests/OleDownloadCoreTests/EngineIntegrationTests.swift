import Foundation
import Testing
@testable import OleDownloadCore

@Suite("HTTP engine against a local server", .serialized)
struct EngineIntegrationTests {
    let engine = HTTPDownloadEngine()

    private func download(_ url: URL, config: EngineConfiguration = testConfig(), resume: ResumeState? = nil,
                          to file: URL, progress: TransferProgress = TransferProgress()) async throws -> EngineResult {
        try await engine.download(EngineJob(url: url, partialFile: file, resume: resume), configuration: config, progress: progress)
    }

    @Test func smallFileSingleConnection() async throws {
        let server = try TestHTTPServer()
        let dir = TempDir()
        let out = dir.file("small.part")
        let result = try await download(server.url("/file?size=1000&seed=1"), to: out)
        #expect(try Data(contentsOf: out) == TestHTTPServer.body(size: 1000, seed: 1))
        #expect(result.totalBytes == 1000)
        #expect(result.response.supportsRanges == true)
        #expect(result.connectionsUsed == 1)  // too small to split
    }

    @Test func segmentedMatchesSingleConnection() async throws {
        let server = try TestHTTPServer()
        let dir = TempDir()
        let size = 3 * 1024 * 1024 + 7   // odd size exercises remainder distribution
        let segmented = dir.file("seg.part")
        let single = dir.file("single.part")
        let r1 = try await download(server.url("/file?size=\(size)&seed=4"), config: testConfig(connections: 4), to: segmented)
        let r2 = try await download(server.url("/file?size=\(size)&seed=4"), config: testConfig(connections: 1), to: single)
        let expected = TestHTTPServer.body(size: size, seed: 4)
        #expect(r1.connectionsUsed == 4)
        #expect(r2.connectionsUsed == 1)
        #expect(try Data(contentsOf: segmented) == expected)
        #expect(try Data(contentsOf: single) == expected)
        #expect(r1.segments.count == 4)
        #expect(SegmentPlanner.isValidTiling(r1.segments, totalLength: Int64(size)))
        // Explicit ranged requests were issued for segments 2...4 (besides the open-ended primary "bytes=0-").
        let ranged = server.requests(path: "/file").compactMap { $0.headers["range"] }.filter { $0 != "bytes=0-" && !$0.hasPrefix("bytes=\(size - 1)-") }
        #expect(ranged.count >= 3)
    }

    @Test func serverIgnoringRangeUsesSingleStream() async throws {
        let server = try TestHTTPServer()
        let dir = TempDir()
        let out = dir.file("norange.part")
        let size = 2 * 1024 * 1024
        let result = try await download(server.url("/file?size=\(size)&seed=2&ranges=0"), to: out)
        #expect(try Data(contentsOf: out) == TestHTTPServer.body(size: size, seed: 2))
        #expect(result.response.supportsRanges == false)
        #expect(result.connectionsUsed == 1)
        #expect(result.segments.isEmpty)
    }

    @Test func unknownLengthDownload() async throws {
        let server = try TestHTTPServer()
        let dir = TempDir()
        let out = dir.file("unknown.part")
        let progress = TransferProgress()
        let result = try await download(server.url("/file?size=300000&seed=3&ranges=0&nolength=1"), to: out, progress: progress)
        #expect(try Data(contentsOf: out) == TestHTTPServer.body(size: 300000, seed: 3))
        #expect(progress.snapshot().expectedLength == nil)
        #expect(result.totalBytes == 300000)
    }

    @Test func incorrectContentRangeFallsBackSafely() async throws {
        let server = try TestHTTPServer()
        let dir = TempDir()
        let out = dir.file("bad.part")
        let size = 1024 * 1024
        let result = try await download(server.url("/file?size=\(size)&seed=5&badrange=1"), to: out)
        // The shifted ranges were rejected and the file was fetched with one plain request instead.
        #expect(try Data(contentsOf: out) == TestHTTPServer.body(size: size, seed: 5))
        #expect(result.response.supportsRanges == false)
        #expect(server.requests(path: "/file").contains { $0.headers["range"] == nil })
    }

    @Test func transientServerErrorOnSegmentIsRetried() async throws {
        let server = try TestHTTPServer()
        let dir = TempDir()
        let out = dir.file("flaky.part")
        let size = 1024 * 1024
        // The first two requests (the primary and one segment) fail with 500; the engine reconnects.
        let url = server.url("/file?size=\(size)&seed=6&fail500=1&key=flaky")
        await #expect(throws: DownloadError.self) { try await download(url, to: out) }  // primary 500 surfaces to the job retry policy
        let result = try await download(url, to: out)                               // job-level retry succeeds
        #expect(try Data(contentsOf: out) == TestHTTPServer.body(size: size, seed: 6))
        #expect(result.totalBytes == Int64(size))
    }

    @Test func interruptedSegmentResumesWithoutDuplication() async throws {
        let server = try TestHTTPServer()
        let dir = TempDir()
        let out = dir.file("interrupt.part")
        let size = 1024 * 1024
        // The first connection dies after 100 000 bytes; the segment continues from the exact offset.
        let result = try await download(server.url("/file?size=\(size)&seed=7&interruptAfter=100000&key=int"), config: testConfig(connections: 1), to: out)
        #expect(try Data(contentsOf: out) == TestHTTPServer.body(size: size, seed: 7))
        #expect(result.totalBytes == Int64(size))
        let resumedFrom = server.requests(path: "/file").compactMap { $0.headers["range"] }.filter { $0 != "bytes=0-" }
        #expect(resumedFrom.contains { $0.hasPrefix("bytes=100000-") })
    }

    @Test func notFoundIsPermanentError() async throws {
        let server = try TestHTTPServer()
        let dir = TempDir()
        do {
            _ = try await download(server.url("/status/404"), to: dir.file("x.part"))
            Issue.record("expected failure")
        } catch let e as DownloadError {
            #expect(e.kind == .notFound)
            #expect(!e.isTransient)
        }
    }

    @Test func authRequiredIsReportedOnce() async throws {
        let server = try TestHTTPServer()
        let dir = TempDir()
        do {
            _ = try await download(server.url("/status/401"), to: dir.file("x.part"))
            Issue.record("expected failure")
        } catch let e as DownloadError {
            #expect(e.kind == .authenticationRequired)
            #expect(!e.isTransient)
        }
        #expect(server.requests(path: "/status/401").count == 1)
    }

    @Test func contentDispositionFileName() async throws {
        let server = try TestHTTPServer()
        let dir = TempDir()
        let result = try await download(server.url("/file?size=10&disposition=r%C3%A9sum%C3%A9%202026.pdf"), to: dir.file("d.part"))
        #expect(result.response.serverFileName == "résumé 2026.pdf")
    }

    @Test func followsRedirect() async throws {
        let server = try TestHTTPServer()
        let dir = TempDir()
        let out = dir.file("r.part")
        let result = try await download(server.url("/redirect?to=%2Ffile%3Fsize%3D5000%26seed%3D8"), to: out)
        #expect(try Data(contentsOf: out) == TestHTTPServer.body(size: 5000, seed: 8))
        #expect(result.response.finalURL?.path == "/file")
    }

    @Test func throttledParallelConnectionsStillComplete() async throws {
        let server = try TestHTTPServer()
        let dir = TempDir()
        let out = dir.file("throttle.part")
        let size = 2 * 1024 * 1024
        var config = testConfig(connections: 4)
        config.segmentRetryLimit = 5
        let result = try await download(server.url("/file?size=\(size)&seed=9&maxParallel=2&chunkSize=16384&delayMs=1"), config: config, to: out)
        #expect(try Data(contentsOf: out) == TestHTTPServer.body(size: size, seed: 9))
        #expect(result.totalBytes == Int64(size))
    }

    @Test func shortRangeResponsesAreContinued() async throws {
        let server = try TestHTTPServer()
        let dir = TempDir()
        let out = dir.file("short.part")
        let size = 1024 * 1024
        // The server caps each range response at 100 000 bytes; segments keep requesting the remainder.
        _ = try await download(server.url("/file?size=\(size)&seed=10&rangeLimit=100000"), config: testConfig(connections: 2), to: out)
        #expect(try Data(contentsOf: out) == TestHTTPServer.body(size: size, seed: 10))
    }

    @Test func pauseAndResumeDoesNotDuplicateOrSkipBytes() async throws {
        let server = try TestHTTPServer()
        let dir = TempDir()
        let out = dir.file("resume.part")
        let size = 1024 * 1024
        let url = server.url("/file?size=\(size)&seed=11&chunkSize=8192&delayMs=5")
        let progress = TransferProgress()
        let task = Task { try await download(url, config: testConfig(connections: 3, minSegment: 128 * 1024), to: out, progress: progress) }
        #expect(await waitUntil { progress.snapshot().bytesReceived > 150_000 })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        let snap = progress.snapshot()
        #expect(snap.durableBytes > 0)
        #expect(snap.durableBytes < Int64(size))
        #expect(SegmentPlanner.isValidTiling(snap.durableSegments, totalLength: Int64(size)))

        let resume = ResumeState(validators: snap.response.validators, expectedLength: Int64(size), supportsRanges: true, segments: snap.durableSegments)
        let fastURL = server.url("/file?size=\(size)&seed=11")
        let before = server.requests.count
        let result = try await download(fastURL, config: testConfig(connections: 3, minSegment: 128 * 1024), resume: resume, to: out)
        #expect(result.resumed)
        #expect(try Data(contentsOf: out) == TestHTTPServer.body(size: size, seed: 11))
        // No resumed request started at byte 0 of a segment that already had data.
        let resumedRanges = server.requests.dropFirst(before).compactMap { $0.headers["range"] }
        for s in snap.durableSegments where s.completed > 0 {
            #expect(!resumedRanges.contains("bytes=\(s.start)-\(s.end)"))
        }
    }

    @Test func changedSourceOnResumeRestartsCleanly() async throws {
        let server = try TestHTTPServer()
        let dir = TempDir()
        let out = dir.file("changed.part")
        let size = 512 * 1024
        let progress = TransferProgress()
        let task = Task {
            try await download(server.url("/file?size=\(size)&seed=12&version=1&chunkSize=8192&delayMs=5"),
                               config: testConfig(connections: 2, minSegment: 64 * 1024), to: out, progress: progress)
        }
        #expect(await waitUntil { progress.snapshot().bytesReceived > 60_000 })
        task.cancel()
        _ = try? await task.value
        let snap = progress.snapshot()
        let resume = ResumeState(validators: snap.response.validators, expectedLength: Int64(size), supportsRanges: true, segments: snap.durableSegments)

        // The file is replaced on the server (new version → new ETag and content).
        let result = try await download(server.url("/file?size=\(size)&seed=12&version=2"), config: testConfig(connections: 2, minSegment: 64 * 1024), resume: resume, to: out)
        #expect(!result.resumed)
        #expect(try Data(contentsOf: out) == TestHTTPServer.body(size: size, seed: 12, version: 2))
    }

    @Test func changingETagDuringSegmentedDownloadIsDetected() async throws {
        let server = try TestHTTPServer()
        let dir = TempDir()
        // Every request sees a different ETag, so segments can never be trusted to belong together.
        // The engine restarts once, then falls back to a single plain connection.
        let size = 1024 * 1024
        let result = try await download(server.url("/file?size=\(size)&seed=13&etag=changing&key=chg"), to: dir.file("c.part"))
        #expect(try Data(contentsOf: dir.file("c.part")) == TestHTTPServer.body(size: size, seed: 13))
        #expect(result.connectionsUsed == 1)
    }

    @Test func zeroLengthFile() async throws {
        let server = try TestHTTPServer()
        let dir = TempDir()
        let out = dir.file("empty.part")
        let result = try await download(server.url("/file?size=0"), to: out)
        #expect(result.totalBytes == 0)
        #expect(try Data(contentsOf: out).isEmpty)
    }

    @Test func speedLimitIsRespected() async throws {
        let server = try TestHTTPServer()
        let dir = TempDir()
        var config = testConfig(connections: 1)
        config.limiters = [BandwidthLimiter(bytesPerSecond: 400_000)]
        let start = Date()
        _ = try await download(server.url("/file?size=1000000&seed=14"), config: config, to: dir.file("slow.part"))
        // 1 MB at 400 KB/s with a 1 s initial burst needs at least ~1.5 s.
        #expect(Date().timeIntervalSince(start) > 1.2)
    }
}
