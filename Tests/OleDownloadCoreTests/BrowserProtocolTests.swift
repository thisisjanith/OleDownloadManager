import Foundation
import Testing
@testable import OleBrowserBridge

@Suite("Browser message validation")
struct BrowserProtocolTests {
    let chromeOrigin = "chrome-extension://adndpcefokbkijmccnbhfkhllcpedgfj/"

    func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    @Test func validAddDownload() throws {
        let data = json(["v": 1, "type": "addDownload", "id": "req-1", "url": "https://example.com/a.zip",
                         "pageUrl": "https://example.com/", "fileName": "a.zip", "mode": "queue", "source": "contextMenu", "origin": chromeOrigin])
        guard case .success(.addDownload(let r)) = BrowserMessageValidator.validateRequest(data, requireOrigin: true) else {
            Issue.record("expected success")
            return
        }
        #expect(r.url == "https://example.com/a.zip")
        #expect(r.mode == .queue)
        #expect(r.origin == chromeOrigin)
    }

    @Test func helloAndStatus() {
        if case .success(.hello) = BrowserMessageValidator.validateRequest(json(["v": 1, "type": "hello", "browser": "chrome"]), requireOrigin: false) {} else { Issue.record("hello") }
        if case .success(.getStatus) = BrowserMessageValidator.validateRequest(json(["v": 1, "type": "getStatus"]), requireOrigin: false) {} else { Issue.record("status") }
    }

    @Test(arguments: [
        (#"{"v":2,"type":"hello"}"#, BrowserProtocolError.unsupportedVersion(2)),
        (#"{"type":"hello"}"#, .invalidField("v")),
        (#"{"v":1,"type":"launchMissiles"}"#, .unknownType),
        (#"{"v":1,"type":"downloadAccepted"}"#, .notARequest),
        (#"{"v":1,"type":"addDownload","url":"file:///etc/passwd"}"#, .invalidField("url")),
        (#"{"v":1,"type":"addDownload","url":"javascript:alert(1)"}"#, .invalidField("url")),
        (#"{"v":1,"type":"addDownload"}"#, .invalidField("url")),
        (#"{"v":1,"type":"addDownload","url":"https://e.com/x","mode":"explode"}"#, .invalidField("mode")),
        (#"{"v":1,"type":"addDownload","url":"https://e.com/x","source":"telepathy"}"#, .invalidField("source")),
        (#"{"v":1,"type":"hello","id":"bad id with spaces"}"#, .invalidField("id")),
    ])
    func rejectsInvalid(message: String, expected: BrowserProtocolError) {
        guard case .failure(let error) = BrowserMessageValidator.validateRequest(Data(message.utf8), requireOrigin: false) else {
            Issue.record("expected failure for \(message)")
            return
        }
        #expect(error == expected)
    }

    @Test func rejectsMalformedAndOversized() {
        #expect(BrowserMessageValidator.validateRequest(Data("not json".utf8), requireOrigin: false) == .failure(.malformedJSON))
        #expect(BrowserMessageValidator.validateRequest(Data("[1,2]".utf8), requireOrigin: false) == .failure(.malformedJSON))
        let big = json(["v": 1, "type": "addDownload", "url": "https://e.com/" + String(repeating: "a", count: 70_000)])
        #expect(BrowserMessageValidator.validateRequest(big, requireOrigin: false) == .failure(.tooLarge))
        let longURL = json(["v": 1, "type": "addDownload", "url": "https://e.com/" + String(repeating: "a", count: 9000)])
        #expect(BrowserMessageValidator.validateRequest(longURL, requireOrigin: false) == .failure(.invalidField("url")))
    }

    @Test func originAllowlist() {
        let msg: [String: Any] = ["v": 1, "type": "getStatus"]
        #expect(BrowserMessageValidator.validateRequest(json(msg), requireOrigin: true) == .failure(.unauthorizedOrigin))
        var withBad = msg
        withBad["origin"] = "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/"
        #expect(BrowserMessageValidator.validateRequest(json(withBad), requireOrigin: true) == .failure(.unauthorizedOrigin))
        var firefox = msg
        firefox["origin"] = "oledownloadmanager@oledownloadmanager.app"
        if case .success = BrowserMessageValidator.validateRequest(json(firefox), requireOrigin: true) {} else { Issue.record("firefox origin") }
        #expect(BrowserProtocol.isAllowedOrigin(chromeOrigin))
        #expect(!BrowserProtocol.isAllowedOrigin("https://evil.example"))
    }

    @Test func framingRoundTrip() throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let payload = Data(#"{"v":1,"type":"hello"}"#.utf8)
        try MessageFraming.writeFrame(fd: fds[1], payload: payload)
        #expect(try MessageFraming.readFrame(fd: fds[0]) == payload)
        // A length prefix beyond the limit is refused without reading the body.
        var huge = UInt32(10_000_000).littleEndian
        _ = write(fds[1], &huge, 4)
        #expect(throws: MessageFraming.FramingError.tooLarge(10_000_000)) { try MessageFraming.readFrame(fd: fds[0]) }
    }

    @Test func ipcServerRoundTrip() async throws {
        let path = NSTemporaryDirectory() + "oledm-\(UUID().uuidString.prefix(8)).sock"
        let server = IPCServer(path: path) { request in
            var reply = BrowserMessage(type: .status, id: "x")
            reply.connected = true
            reply.message = String(decoding: request, as: UTF8.self)
            return (try? reply.encoded()) ?? Data()
        }
        try server.start()
        defer { server.stop() }
        var st = stat()
        #expect(lstat(path, &st) == 0)
        #expect(st.st_mode & 0o077 == 0)   // socket not accessible to other users
        let response = try IPCClient.send(Data(#"{"ping":1}"#.utf8), socketPath: path, timeout: 5)
        let decoded = try JSONDecoder().decode(BrowserMessage.self, from: response)
        #expect(decoded.connected == true)
        #expect(decoded.message == #"{"ping":1}"#)
    }

    @Test func ipcClientReportsAppNotRunning() {
        do {
            _ = try IPCClient.send(Data("{}".utf8), socketPath: NSTemporaryDirectory() + "nothing-\(UUID().uuidString.prefix(6)).sock", timeout: 1)
            Issue.record("expected failure")
        } catch {
            #expect(error.appNotRunning)
        }
    }
}
