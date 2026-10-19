import Foundation
import Testing
@testable import OleBrowserBridge
@testable import OleDownloadCore

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

@Suite("Native host installation and end-to-end bridge", .serialized)
struct NativeHostTests {
    @Test func installsAndRemovesManifests() throws {
        let support = TempDir()
        let installer = NativeHostInstaller(applicationSupport: support.url)
        let host = "/bin/echo"
        #expect(installer.status(for: .chrome, hostPath: host) == .browserNotFound)
        try FileManager.default.createDirectory(at: support.url.appendingPathComponent("Google/Chrome"), withIntermediateDirectories: true)
        #expect(installer.status(for: .chrome, hostPath: host) == .notInstalled)
        try installer.install(for: .chrome, hostPath: host)
        try installer.install(for: .firefox, hostPath: host)
        #expect(installer.status(for: .chrome, hostPath: host) == .installed)
        if case .stale = installer.status(for: .chrome, hostPath: "/other") {} else { Issue.record("expected stale") }

        let chrome = try JSONSerialization.jsonObject(with: Data(contentsOf: installer.manifestURL(for: .chrome))) as? [String: Any]
        #expect(chrome?["name"] as? String == "com.oledownloadmanager.native")
        #expect(chrome?["allowed_origins"] as? [String] == ["chrome-extension://adndpcefokbkijmccnbhfkhllcpedgfj/"])
        let firefox = try JSONSerialization.jsonObject(with: Data(contentsOf: installer.manifestURL(for: .firefox))) as? [String: Any]
        #expect(firefox?["allowed_extensions"] as? [String] == ["oledownloadmanager@oledownloadmanager.app"])

        try installer.uninstall(for: .chrome)
        #expect(installer.status(for: .chrome, hostPath: host) == .notInstalled)
    }

    /// Runs the real OleNativeHost executable exactly as a browser would (stdin/stdout framing,
    /// caller origin as argument) against an in-process IPC server.
    @Test func hostRelaysToAppAndEnforcesOrigin() async throws {
        let hostURL = try #require(Self.hostExecutable())
        let socket = NSTemporaryDirectory() + "oledm-e2e-\(UUID().uuidString.prefix(6)).sock"
        let server = IPCServer(path: socket) { data in
            guard case .success(let req) = BrowserMessageValidator.validateRequest(data, requireOrigin: true) else {
                return (try? BrowserMessage.error(id: nil, code: "rejected", message: "bad").encoded()) ?? Data()
            }
            var reply = BrowserMessage(type: .downloadAccepted, id: req.id)
            reply.downloadId = "1234"
            return (try? reply.encoded()) ?? Data()
        }
        try server.start()
        defer { server.stop() }

        let ok = try Self.runHost(hostURL, args: ["chrome-extension://adndpcefokbkijmccnbhfkhllcpedgfj/"], socket: socket,
                                  messages: [#"{"v":1,"type":"addDownload","id":"r1","url":"https://example.com/a.zip","origin":"chrome-extension://spoofed/"}"#])
        #expect(ok.count == 1)
        let reply = try JSONDecoder().decode(BrowserMessage.self, from: ok[0])
        #expect(reply.type == .downloadAccepted)
        #expect(reply.downloadId == "1234")

        let invalid = try Self.runHost(hostURL, args: ["chrome-extension://adndpcefokbkijmccnbhfkhllcpedgfj/"], socket: socket,
                                       messages: [#"{"v":1,"type":"addDownload","url":"file:///etc/passwd"}"#])
        #expect(try JSONDecoder().decode(BrowserMessage.self, from: invalid[0]).code == "invalidField")

        let refused = try Self.runHost(hostURL, args: ["chrome-extension://notallowedaaaaaaaaaaaaaaaaaaaaaa/"], socket: socket,
                                       messages: [#"{"v":1,"type":"getStatus"}"#])
        #expect(try JSONDecoder().decode(BrowserMessage.self, from: refused[0]).code == "unauthorizedOrigin")

        // Firefox passes (manifest path, extension id).
        let firefox = try Self.runHost(hostURL, args: ["/path/to/manifest.json", "oledownloadmanager@oledownloadmanager.app"], socket: socket,
                                       messages: [#"{"v":1,"type":"addDownload","id":"f1","url":"https://example.com/b.zip"}"#])
        #expect(try JSONDecoder().decode(BrowserMessage.self, from: firefox[0]).type == .downloadAccepted)
    }

    @Test func hostReportsAppNotRunning() throws {
        let hostURL = try #require(Self.hostExecutable())
        let replies = try Self.runHost(hostURL, args: ["chrome-extension://adndpcefokbkijmccnbhfkhllcpedgfj/"],
                                       socket: NSTemporaryDirectory() + "absent-\(UUID().uuidString.prefix(6)).sock",
                                       messages: [#"{"v":1,"type":"getStatus","id":"s1"}"#])
        let status = try JSONDecoder().decode(BrowserMessage.self, from: replies[0])
        #expect(status.connected == false)
        #expect(status.code == "appNotRunning")
    }

    static func hostExecutable(file: String = #filePath) -> URL? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["OLEDM_NATIVE_HOST_PATH"] { candidates.append(URL(fileURLWithPath: override)) }
        // The test bundle normally sits next to the built products (e.g. .build/debug).
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("OleNativeHost"))
        }
        let root = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(root.appendingPathComponent(".build/debug/OleNativeHost"))
        candidates.append(root.appendingPathComponent(".build/release/OleNativeHost"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func runHost(_ url: URL, args: [String], socket: String, messages: [String]) throws -> [Data] {
        let process = Process()
        process.executableURL = url
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env[IPCPaths.environmentOverride] = socket
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        for m in messages { input.fileHandleForWriting.write(MessageFraming.frame(Data(m.utf8))) }
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        var frames: [Data] = []
        var i = 0
        while i + 4 <= out.count {
            let len = out[i..<(i + 4)].withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
            frames.append(out[(i + 4)..<(i + 4 + len)])
            i += 4 + len
        }
        return frames
    }
}
