import Foundation
import Network

/// A small HTTP/1.1 server bound to 127.0.0.1 on a random port, used by integration tests and UI tests.
/// Every response closes the connection. Behaviour is selected with query parameters on `/file`:
///
///   size, seed              body length and deterministic content seed
///   ranges=0                ignore Range headers (always 200)
///   badrange=1              answer ranges with a shifted Content-Range
///   nolength=1              omit Content-Length on 200 responses (close-delimited body)
///   etag=X | etag=changing  fixed ETag, or one that changes on every request
///   version=N               content and ETag version (lets a test "replace" the file)
///   fail500=N&key=K         first N requests for key K get HTTP 500
///   interruptAfter=N&key=K  first request for key K closes the connection after N body bytes
///   chunkSize, delayMs      stream slowly (for pause/cancel tests)
///   maxParallel=N           answer 503 when more than N requests are in flight
///   rangeLimit=N            serve at most N bytes per range response
///   disposition=NAME        send Content-Disposition with filename* (UTF-8)
/// Other routes: /status/<code>, /redirect?to=<path>, /retryafter?key=K (429 once, then a small file).
final class TestHTTPServer: @unchecked Sendable {
    struct RecordedRequest: Sendable {
        let path: String
        let query: [String: String]
        let headers: [String: String]
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "test-http-server", attributes: .concurrent)
    private let lock = NSLock()
    private var counters: [String: Int] = [:]
    private var inFlight = 0
    private var _requests: [RecordedRequest] = []
    private(set) var port: UInt16 = 0

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    deinit { listener.cancel() }

    func stop() { listener.cancel() }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func url(_ pathAndQuery: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(pathAndQuery)")! }

    var requests: [RecordedRequest] { lock.withLock { _requests } }

    func requests(path: String) -> [RecordedRequest] { requests.filter { $0.path == path } }

    /// Deterministic file content shared with tests for byte-exact comparisons.
    static func body(size: Int, seed: Int, version: Int = 0) -> Data {
        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<size {
                p[i] = UInt8(truncatingIfNeeded: (i &* 31) ^ (i >> 7) &+ seed &* 17 &+ version &* 101)
            }
        }
        return data
    }

    private func bump(_ key: String) -> Int {
        lock.withLock {
            counters[key, default: 0] += 1
            return counters[key]!
        }
    }

    // MARK: Connection handling

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveHeaders(conn, buffer: Data())
    }

    private func receiveHeaders(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
                self.handle(head, conn: conn)
            } else if complete || error != nil || buf.count > 65536 {
                conn.cancel()
            } else {
                self.receiveHeaders(conn, buffer: buf)
            }
        }
    }

    private func handle(_ head: String, conn: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { conn.cancel(); return }
        let target = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let comps = URLComponents(string: target)
        let path = comps?.path ?? target
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        lock.withLock { _requests.append(RecordedRequest(path: path, query: query, headers: headers)) }
        let isHead = parts[0] == "HEAD"
        route(path: path, query: query, headers: headers, conn: conn, isHead: isHead)
    }

    private func route(path: String, query: [String: String], headers: [String: String], conn: NWConnection, isHead: Bool) {
        if path.hasPrefix("/status/"), let code = Int(path.dropFirst("/status/".count)) {
            send(conn, status: code, headers: ["Content-Type": "text/plain"], body: Data("status \(code)".utf8))
            return
        }
        switch path {
        case "/redirect":
            let to = query["to"] ?? "/file?size=10"
            send(conn, status: 302, headers: ["Location": to], body: Data())
        case "/retryafter":
            let n = bump("retryafter-" + (query["key"] ?? ""))
            if n == 1 {
                send(conn, status: 429, headers: ["Retry-After": "1"], body: Data())
            } else {
                send(conn, status: 200, headers: ["Content-Type": "application/octet-stream"], body: Self.body(size: 1000, seed: 1))
            }
        case "/file":
            serveFile(query: query, headers: headers, conn: conn, isHead: isHead)
        default:
            send(conn, status: 404, headers: [:], body: Data("not found".utf8))
        }
    }

    private func serveFile(query: [String: String], headers: [String: String], conn: NWConnection, isHead: Bool) {
        let size = Int(query["size"] ?? "1024") ?? 1024
        let seed = Int(query["seed"] ?? "0") ?? 0
        let version = Int(query["version"] ?? "0") ?? 0
        let key = query["key"] ?? ""

        if let maxParallel = query["maxParallel"].flatMap(Int.init) {
            let current = lock.withLock { inFlight += 1; return inFlight }
            if current > maxParallel {
                lock.withLock { inFlight -= 1 }
                send(conn, status: 503, headers: ["Retry-After": "0"], body: Data())
                return
            }
        }
        if let fails = query["fail500"].flatMap(Int.init), bump("fail500-" + key) <= fails {
            releaseParallel(query)
            send(conn, status: 500, headers: [:], body: Data("temporary".utf8))
            return
        }

        let body = Self.body(size: size, seed: seed, version: version)
        var respHeaders = ["Content-Type": "application/octet-stream"]
        var etag: String?
        if query["etag"] == "changing" {
            etag = "\"e\(bump("etag-" + key))\""
        } else if let e = query["etag"] {
            etag = "\"\(e)-v\(version)\""
        } else {
            etag = "\"v\(version)-\(size)-\(seed)\""
        }
        respHeaders["ETag"] = etag
        respHeaders["Last-Modified"] = "Tue, 0\(min(version, 9) + 1) Sep 2026 10:00:00 GMT"
        if let name = query["disposition"] {
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
            respHeaders["Content-Disposition"] = "attachment; filename=\"fallback.bin\"; filename*=UTF-8''\(encoded)"
        }
        let honorRanges = query["ranges"] != "0"
        if honorRanges { respHeaders["Accept-Ranges"] = "bytes" }

        var status = 200
        var slice = 0..<size
        if honorRanges, let rangeHeader = headers["range"], let requested = parseRange(rangeHeader, size: size) {
            let ifRange = headers["if-range"]
            let ifRangeOK = ifRange == nil || ifRange == etag || ifRange == respHeaders["Last-Modified"]
            if ifRangeOK {
                if requested.isEmpty {
                    releaseParallel(query)
                    send(conn, status: 416, headers: ["Content-Range": "bytes */\(size)"], body: Data())
                    return
                }
                status = 206
                slice = requested
                if let limit = query["rangeLimit"].flatMap(Int.init), slice.count > limit {
                    slice = slice.lowerBound..<(slice.lowerBound + limit)
                }
                let shift = query["badrange"] == "1" ? 1 : 0
                respHeaders["Content-Range"] = "bytes \(slice.lowerBound + shift)-\(slice.upperBound - 1 + shift)/\(size)"
            }
        }
        let payload = body.subdata(in: slice)
        if !(status == 200 && query["nolength"] == "1") {
            respHeaders["Content-Length"] = "\(payload.count)"
        }
        var interruptAt: Int?
        if let n = query["interruptAfter"].flatMap(Int.init), bump("interrupt-" + key) == 1 { interruptAt = n }
        let chunk = Int(query["chunkSize"] ?? "") ?? 65536
        let delay = Int(query["delayMs"] ?? "") ?? 0
        sendStreaming(conn, status: status, headers: respHeaders, body: isHead ? Data() : payload,
                      chunkSize: max(1, chunk), delayMs: delay, interruptAt: interruptAt) { [weak self] in
            self?.releaseParallel(query)
        }
    }

    private func releaseParallel(_ query: [String: String]) {
        if query["maxParallel"] != nil { lock.withLock { inFlight -= 1 } }
    }

    /// Parses a single "bytes=a-b" / "bytes=a-" / "bytes=-n" range. Returns an empty range when unsatisfiable.
    private func parseRange(_ header: String, size: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let spec = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard spec.count == 2 else { return nil }
        if spec[0].isEmpty, let n = Int(spec[1]) { return max(0, size - n)..<size }
        guard let a = Int(spec[0]) else { return nil }
        if a >= size { return 0..<0 }
        let b = spec[1].isEmpty ? size - 1 : min(Int(spec[1]) ?? size - 1, size - 1)
        guard b >= a else { return 0..<0 }
        return a..<(b + 1)
    }

    private func headerData(status: Int, headers: [String: String]) -> Data {
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8)
    }

    private func send(_ conn: NWConnection, status: Int, headers: [String: String], body: Data) {
        var h = headers
        h["Content-Length"] = "\(body.count)"
        var data = headerData(status: status, headers: h)
        data.append(body)
        conn.send(content: data, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func sendStreaming(_ conn: NWConnection, status: Int, headers: [String: String], body: Data,
                               chunkSize: Int, delayMs: Int, interruptAt: Int?, done: @escaping @Sendable () -> Void) {
        conn.send(content: headerData(status: status, headers: headers), completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { conn.cancel(); done(); return }
            self.sendChunk(conn, body: body, offset: 0, chunkSize: chunkSize, delayMs: delayMs, interruptAt: interruptAt, done: done)
        })
    }

    private func sendChunk(_ conn: NWConnection, body: Data, offset: Int, chunkSize: Int, delayMs: Int,
                           interruptAt: Int?, done: @escaping @Sendable () -> Void) {
        if let interruptAt, offset >= interruptAt {
            conn.forceCancel()   // abrupt close mid-body
            done()
            return
        }
        guard offset < body.count else {
            conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in conn.cancel(); done() })
            return
        }
        let limit = min(body.count, offset + chunkSize)
        let end = interruptAt.map { min(limit, max($0, offset + 1)) } ?? limit
        let piece = body.subdata(in: offset..<end)
        conn.send(content: piece, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { conn.cancel(); done(); return }
            let next: @Sendable () -> Void = { self.sendChunk(conn, body: body, offset: end, chunkSize: chunkSize, delayMs: delayMs, interruptAt: interruptAt, done: done) }
            if delayMs > 0 {
                self.queue.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: next)
            } else {
                next()
            }
        })
    }
}
