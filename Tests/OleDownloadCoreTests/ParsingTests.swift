import Foundation
import Testing
@testable import OleDownloadCore

@Suite("URL validation")
struct URLValidationTests {
    @Test(arguments: ["https://example.com/file.zip", "http://example.com", "HTTPS://Example.com:8443/a%20b?x=1",
                      "example.com/file.zip", "  https://example.com/x  ", "http://127.0.0.1:8080/x", "https://example.com/a b.zip"])
    func accepts(_ s: String) throws {
        let v = try URLValidator.validate(s)
        #expect(v.url.scheme == "http" || v.url.scheme == "https")
    }

    @Test func rejectsUnsupportedSchemes() {
        for s in ["ftp://example.com/x", "file:///etc/passwd", "javascript:alert(1)", "mailto:a@b.c", "data:text/plain,hi"] {
            #expect(throws: URLValidationError.self) { try URLValidator.validate(s) }
        }
    }

    @Test func rejectsMalformed() {
        #expect(throws: URLValidationError.empty) { try URLValidator.validate("   ") }
        #expect(throws: URLValidationError.self) { try URLValidator.validate("https://") }
        #expect(throws: URLValidationError.self) { try URLValidator.validate("not a url") }
        #expect(throws: URLValidationError.tooLong) { try URLValidator.validate("https://e.com/" + String(repeating: "a", count: 9000)) }
        #expect(throws: URLValidationError.self) { try URLValidator.validate("https://exa\u{0}mple.com") }
    }

    @Test func bareHostGetsHTTPS() throws {
        #expect(try URLValidator.validate("example.com/a.zip").url.absoluteString == "https://example.com/a.zip")
        #expect(try URLValidator.validate("localhost:8080/a").url.absoluteString == "https://localhost:8080/a")
    }

    @Test func embeddedCredentialsAreExtracted() throws {
        let v = try URLValidator.validate("https://alice:s%40cret@example.com/file")
        #expect(v.embeddedUser == "alice")
        #expect(v.embeddedPassword == "s@cret")
        #expect(v.url.absoluteString == "https://example.com/file")
    }

    @Test func privateAddressClassification() {
        for h in ["localhost", "127.0.0.1", "10.1.2.3", "192.168.1.1", "172.20.0.1", "169.254.1.1", "[::1]", "fd00::1", "printer.local", "intranet"] {
            #expect(NetworkAddressClassifier.isPrivateOrLocal(host: h), "\(h)")
        }
        for h in ["example.com", "8.8.8.8", "172.32.0.1", "2001:4860::8888"] {
            #expect(!NetworkAddressClassifier.isPrivateOrLocal(host: h), "\(h)")
        }
    }

    @Test func redirectPolicy() {
        let policy = RedirectPolicy()
        let original = URL(string: "https://example.com/a")!
        #expect(policy.check(from: original, to: URL(string: "https://cdn.example.net/a")!, originalURL: original, redirectCount: 1) == nil)
        #expect(policy.check(from: original, to: URL(string: "http://example.com/a")!, originalURL: original, redirectCount: 1)?.kind == .unsafeRedirect)
        #expect(policy.check(from: original, to: URL(string: "https://192.168.0.1/admin")!, originalURL: original, redirectCount: 1)?.kind == .unsafeRedirect)
        #expect(policy.check(from: original, to: URL(string: "ftp://example.com/a")!, originalURL: original, redirectCount: 1)?.kind == .unsafeRedirect)
        #expect(policy.check(from: original, to: URL(string: "https://example.com/b")!, originalURL: original, redirectCount: 11)?.kind == .tooManyRedirects)
        // A user who deliberately downloads from their own LAN may be redirected within it.
        let lan = URL(string: "http://192.168.0.5/file")!
        #expect(policy.check(from: lan, to: URL(string: "http://192.168.0.6/file")!, originalURL: lan, redirectCount: 1) == nil)
    }
}

@Suite("HTTP header parsing")
struct HeaderParsingTests {
    @Test func contentRange() {
        #expect(ContentRange.parse("bytes 0-99/1000") == ContentRange(first: 0, last: 99, completeLength: 1000))
        #expect(ContentRange.parse("bytes 100-199/*") == ContentRange(first: 100, last: 199, completeLength: nil))
        #expect(ContentRange.parse("Bytes 5-5/6")?.length == 1)
        #expect(ContentRange.parse("bytes */1000") == nil)
        #expect(ContentRange.parse("bytes 10-5/100") == nil)
        #expect(ContentRange.parse("bytes 0-99/50") == nil)      // last beyond complete length
        #expect(ContentRange.parse("items 0-1/2") == nil)
        #expect(ContentRange.parse("bytes -1-5/10") == nil)
        #expect(ContentRange.parse("bytes 0-99999999999999999999/1") == nil)
        #expect(ContentRange.parse(nil) == nil)
    }

    @Test func contentDisposition() {
        #expect(ContentDisposition.fileName(from: "attachment; filename=\"report.pdf\"") == "report.pdf")
        #expect(ContentDisposition.fileName(from: "attachment; filename=plain.txt") == "plain.txt")
        #expect(ContentDisposition.fileName(from: "attachment; filename=\"a.bin\"; filename*=UTF-8''%E2%82%AC%20rates.txt") == "€ rates.txt")
        #expect(ContentDisposition.fileName(from: "attachment; filename*=iso-8859-1'en'%A3%20rates.txt") == "£ rates.txt")
        #expect(ContentDisposition.fileName(from: "attachment; filename=\"quote\\\"d.txt\"") == "quote\"d.txt")
        #expect(ContentDisposition.fileName(from: "inline") == nil)
        #expect(ContentDisposition.fileName(from: "attachment; filename=\"../../etc/passwd\"") == "../../etc/passwd") // sanitized later
    }

    @Test func validators() {
        let a = ResourceValidators(etag: "\"x\"", lastModified: "Mon", contentLength: 10)
        #expect(!a.conflicts(with: ResourceValidators(etag: "\"x\"", lastModified: nil, contentLength: 10)))
        #expect(a.conflicts(with: ResourceValidators(etag: "\"y\"", lastModified: nil, contentLength: nil)))
        #expect(a.conflicts(with: ResourceValidators(etag: nil, lastModified: nil, contentLength: 11)))
        #expect(a.ifRangeValue == "\"x\"")
        #expect(ResourceValidators(etag: "W/\"x\"", lastModified: "Mon").ifRangeValue == "Mon")
    }

    @Test func retryAfter() {
        #expect(RetryPolicy.parseRetryAfter("120") == 120)
        #expect(RetryPolicy.parseRetryAfter("-1") == nil)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let later = RetryPolicy.parseRetryAfter("Mon, 12 Jan 1970 13:46:50 GMT", now: now)
        #expect(later.map { abs($0 - 10) < 1 } == true)
        #expect(RetryPolicy.parseRetryAfter("soon") == nil)
    }

    @Test func customHeaders() throws {
        let parsed = try HTTPHeaderValidator.parse("X-Token: abc\nAccept: */*\n\n")
        #expect(parsed == ["X-Token": "abc", "Accept": "*/*"])
        #expect(throws: HTTPHeaderValidator.Problem.reserved("Range")) { try HTTPHeaderValidator.parse("Range: bytes=0-") }
        #expect(throws: HTTPHeaderValidator.Problem.self) { try HTTPHeaderValidator.validate(name: "Bad Name", value: "x") }
        #expect(throws: HTTPHeaderValidator.Problem.self) { try HTTPHeaderValidator.validate(name: "X", value: "a\r\nInjected: 1") }
    }
}

@Suite("File names")
struct FileNameTests {
    @Test(arguments: [
        ("report.pdf", "report.pdf"),
        ("../../etc/passwd", "passwd"),
        ("..\\..\\windows\\evil.exe", "evil.exe"),
        ("a:b.txt", "a_b.txt"),
        (".hidden", "hidden"),
        ("...", "download"),
        ("..", "download"),
        ("", "download"),
        ("bell\u{07}.txt", "bell.txt"),
        ("trailing. ", "trailing"),
        ("evil\u{202E}fdp.exe", "evilfdp.exe"),
        ("caf\u{0065}\u{0301}.txt", "caf\u{00E9}.txt"),
        ("日本語ファイル.zip", "日本語ファイル.zip"),
    ])
    func sanitize(input: String, expected: String) {
        #expect(FileNameSanitizer.sanitize(input) == expected)
    }

    @Test func longNamesKeepExtension() {
        let name = String(repeating: "é", count: 300) + ".tar"
        let s = FileNameSanitizer.sanitize(name)
        #expect(s.utf8.count <= 255)
        #expect(s.hasSuffix(".tar"))
    }

    @Test func suggestedNames() {
        #expect(FileNameSanitizer.suggestedName(contentDisposition: "attachment; filename=\"x.zip\"", url: URL(string: "https://e.com/y.bin"), mimeType: nil) == "x.zip")
        #expect(FileNameSanitizer.suggestedName(contentDisposition: nil, url: URL(string: "https://e.com/dir/My%20File.dmg?x=1"), mimeType: nil) == "My File.dmg")
        #expect(FileNameSanitizer.suggestedName(contentDisposition: nil, url: URL(string: "https://e.com/"), mimeType: "application/pdf") == "download.pdf")
        #expect(FileNameSanitizer.suggestedName(contentDisposition: nil, url: URL(string: "https://e.com/get"), mimeType: "application/zip") == "get.zip")
    }

    @Test func safeDestinationStaysInsideDirectory() {
        let dir = URL(fileURLWithPath: "/tmp/dl", isDirectory: true)
        let d = FileNameSanitizer.safeDestination(directory: dir, name: "../../x")
        #expect(d?.deletingLastPathComponent().lastPathComponent == "dl")
    }

    @Test func numbering() {
        #expect(FileNameSanitizer.numbered("a.zip", 1) == "a (1).zip")
        #expect(FileNameSanitizer.numbered("archive.tar.gz", 2) == "archive (2).tar.gz")
        #expect(FileNameSanitizer.numbered("README", 3) == "README (3)")
    }

    @Test func classification() {
        let c = FileCategory.defaults
        #expect(FileCategory.classify(fileName: "x.PDF", categories: c) == "documents")
        #expect(FileCategory.classify(fileName: "x.dmg", categories: c) == "applications")
        #expect(FileCategory.classify(fileName: "x.tar.gz", categories: c) == "archives")
        #expect(FileCategory.classify(fileName: "movie.mkv", categories: c) == "video")
        #expect(FileCategory.classify(fileName: "song.flac", categories: c) == "audio")
        #expect(FileCategory.classify(fileName: "pic.heic", categories: c) == "images")
        #expect(FileCategory.classify(fileName: "noext", categories: c) == "other")
        #expect(FileCategory.classify(fileName: "x.weird", categories: c) == "other")
    }

    @Test func redaction() {
        let url = URL(string: "https://user:pw@cdn.example.com/f.zip?X-Amz-Signature=abc&token=t&name=ok#frag")!
        let r = Redactor.redact(url)
        #expect(!r.contains("abc"))
        #expect(!r.contains("pw"))
        #expect(!r.contains("=t&"))
        #expect(r.contains("name=ok"))
        #expect(Redactor.redact(headers: ["Authorization": "Bearer x", "Accept": "*/*"]) == ["Authorization": "REDACTED", "Accept": "*/*"])
    }
}

@Suite("Segments, progress and speed")
struct SegmentAndSpeedTests {
    @Test func specExample100MiB() {
        let s = SegmentPlanner.plan(totalLength: 100 * 1024 * 1024, count: 4)
        #expect(s.map(\.start) == [0, 26_214_400, 52_428_800, 78_643_200])
        #expect(s.map(\.end) == [26_214_399, 52_428_799, 78_643_199, 104_857_599])
    }

    @Test(arguments: [(Int64(1), 4), (10, 3), (1001, 8), (7, 7), (5, 10), (Int64(1) << 40, 8)])
    func tilingIsExact(total: Int64, count: Int) {
        let s = SegmentPlanner.plan(totalLength: total, count: count)
        #expect(SegmentPlanner.isValidTiling(s, totalLength: total))
        #expect(s.count == min(count, Int(min(total, Int64(Int.max)))))
        let lengths = s.map(\.length)
        #expect((lengths.max() ?? 0) - (lengths.min() ?? 0) <= 1)
    }

    @Test func emptyAndInvalidTilings() {
        #expect(SegmentPlanner.plan(totalLength: 0, count: 4).isEmpty)
        let gap = [DownloadSegment(index: 0, start: 0, end: 9), DownloadSegment(index: 1, start: 11, end: 19)]
        #expect(!SegmentPlanner.isValidTiling(gap, totalLength: 20))
        let overlap = [DownloadSegment(index: 0, start: 0, end: 10), DownloadSegment(index: 1, start: 10, end: 19)]
        #expect(!SegmentPlanner.isValidTiling(overlap, totalLength: 20))
        let overfull = [DownloadSegment(index: 0, start: 0, end: 9, completed: 11)]
        #expect(!SegmentPlanner.isValidTiling(overfull, totalLength: 10))
    }

    @Test func connectionCount() {
        #expect(SegmentPlanner.connectionCount(totalLength: 100, maxConnections: 8, minimumSegmentSize: 1 << 20) == 1)
        #expect(SegmentPlanner.connectionCount(totalLength: 3 << 20, maxConnections: 8, minimumSegmentSize: 1 << 20) == 3)
        #expect(SegmentPlanner.connectionCount(totalLength: 100 << 20, maxConnections: 4, minimumSegmentSize: 1 << 20) == 4)
        #expect(SegmentPlanner.connectionCount(totalLength: 100 << 20, maxConnections: 1, minimumSegmentSize: 1 << 20) == 1)
    }

    @Test func rollingSpeed() {
        var m = SpeedMonitor(window: 5)
        for t in 0...10 { m.record(totalBytes: Int64(t) * 1_000_000, at: TimeInterval(t)) }
        #expect(abs(m.currentSpeed - 1_000_000) < 1)
        #expect(abs(m.smoothedSpeed - 1_000_000) < 50_000)
        // Speed drops: the window forgets old fast samples.
        for t in 11...20 { m.record(totalBytes: 10_000_000 + Int64(t - 10) * 100_000, at: TimeInterval(t)) }
        #expect(abs(m.currentSpeed - 100_000) < 1)
    }

    @Test func speedHandlesDegenerateInput() {
        var m = SpeedMonitor()
        #expect(m.currentSpeed == 0)
        m.record(totalBytes: 100, at: 5)
        m.record(totalBytes: 200, at: 5)          // zero elapsed time
        #expect(m.currentSpeed.isFinite)
        m.record(totalBytes: 50, at: 6)           // counter reset (restart)
        #expect(m.currentSpeed >= 0)
        m.record(totalBytes: Int64.max, at: 7)
        #expect(m.currentSpeed.isFinite)
    }

    @Test func etaAndProgress() {
        #expect(SpeedMonitor.eta(remaining: 1000, speed: 100) == 10)
        #expect(SpeedMonitor.eta(remaining: 1000, speed: 0) == nil)
        #expect(SpeedMonitor.eta(remaining: 1000, speed: .nan) == nil)
        var r = DownloadRecord(sourceURL: URL(string: "https://e.com/a")!, fileName: "a", destinationDirectory: URL(fileURLWithPath: "/tmp"), categoryID: "other")
        #expect(r.progressFraction == nil)       // unknown size: no invented percentage
        r.expectedLength = 200
        r.bytesReceived = 50
        #expect(r.progressFraction == 0.25)
        r.bytesReceived = 500
        #expect(r.progressFraction == 1)
    }
}

@Suite("Retry policy")
struct RetryPolicyTests {
    @Test func exponentialBackoffWithJitter() {
        let p = RetryPolicy(maxRetries: 5, baseDelay: 2, multiplier: 2, maxDelay: 60, jitter: 0.2)
        #expect(p.delay(forAttempt: 1, random: { 0.5 }) == 2)
        #expect(p.delay(forAttempt: 2, random: { 0.5 }) == 4)
        #expect(p.delay(forAttempt: 3, random: { 0.5 }) == 8)
        #expect(p.delay(forAttempt: 10, random: { 0.5 }) == 60)
        #expect(abs(p.delay(forAttempt: 1, random: { 0 }) - 1.6) < 1e-9)
        #expect(abs(p.delay(forAttempt: 1, random: { 1 }) - 2.4) < 1e-9)
        #expect(p.delay(forAttempt: 1000, random: { 1 }).isFinite)
    }

    @Test func retryAfterWinsButIsCapped() {
        let p = RetryPolicy(maxRetryAfter: 600)
        #expect(p.delay(forAttempt: 1, retryAfter: 30) == 30)
        #expect(p.delay(forAttempt: 1, retryAfter: 99_999) == 600)
    }

    @Test func onlyTransientErrorsRetry() {
        let p = RetryPolicy(maxRetries: 2)
        #expect(p.shouldRetry(error: .http(status: 503), retriesSoFar: 0))
        #expect(p.shouldRetry(error: .http(status: 429), retriesSoFar: 1))
        #expect(p.shouldRetry(error: .http(status: 408), retriesSoFar: 0))
        #expect(!p.shouldRetry(error: .http(status: 503), retriesSoFar: 2))
        #expect(!p.shouldRetry(error: .http(status: 404), retriesSoFar: 0))
        #expect(!p.shouldRetry(error: .http(status: 401), retriesSoFar: 0))
        #expect(!p.shouldRetry(error: .http(status: 403), retriesSoFar: 0))
        #expect(!p.shouldRetry(error: DownloadError.from(urlError: URLError(.serverCertificateUntrusted)), retriesSoFar: 0))
        #expect(p.shouldRetry(error: DownloadError.from(urlError: URLError(.networkConnectionLost)), retriesSoFar: 0))
        #expect(p.shouldRetry(error: DownloadError.from(urlError: URLError(.cannotFindHost)), retriesSoFar: 0))
        #expect(!p.shouldRetry(error: DownloadError.from(posix: ENOSPC), retriesSoFar: 0))
        #expect(DownloadError.from(posix: ENOENT).kind == .destinationUnavailable)
        #expect(DownloadError.from(posix: EACCES).kind == .permissionDenied)
    }
}
