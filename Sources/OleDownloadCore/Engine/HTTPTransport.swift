import Foundation

public struct BasicCredentials: Sendable, Equatable {
    public var user: String
    public var password: String
    public init(user: String, password: String) {
        self.user = user
        self.password = password
    }
}

/// One-shot result box bridging delegate callbacks to async/await.
final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<T, Error>?

    func resolve(_ r: Result<T, Error>) {
        let cont: CheckedContinuation<T, Error>? = lock.withLock {
            guard result == nil else { return nil }
            result = r
            let c = continuation
            continuation = nil
            return c
        }
        cont?.resume(with: r)
    }

    var isResolved: Bool { lock.withLock { result != nil } }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            let ready: Result<T, Error>? = lock.withLock {
                if let result { return result }
                continuation = c
                return nil
            }
            if let ready { c.resume(with: ready) }
        }
    }
}

/// A single HTTP request whose response is held until the engine decides to accept it.
final class DataTransfer: @unchecked Sendable {
    let task: URLSessionDataTask
    private let lock = NSLock()
    private var pendingDisposition: ((URLSession.ResponseDisposition) -> Void)?
    private var sink: RangeWriter?
    private var stoppedAtLimit = false
    private var failure: Error?
    private var limiters: [BandwidthLimiter]
    let responseBox = OneShot<HTTPURLResponse>()
    let completionBox = OneShot<Void>()
    var redirectCount = 0
    var blockedRedirect: DownloadError?

    init(task: URLSessionDataTask, limiters: [BandwidthLimiter]) {
        self.task = task
        self.limiters = limiters
    }

    /// Starts the request and waits for response headers, bounded by `timeout`.
    func response(timeout: TimeInterval) async throws -> HTTPURLResponse {
        task.resume()
        let watchdog = Task { [weak self] in
            try await Task.sleep(for: .seconds(timeout))
            guard let self, !self.responseBox.isResolved else { return }
            self.responseBox.resolve(.failure(DownloadError(.timedOut, "The server did not respond within \(Int(timeout)) seconds.")))
            self.task.cancel()
        }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler {
            try await responseBox.value()
        } onCancel: {
            self.cancel()
        }
    }

    /// Lets the body flow into `writer`.
    func accept(into writer: RangeWriter) {
        let handler: ((URLSession.ResponseDisposition) -> Void)? = lock.withLock {
            sink = writer
            let h = pendingDisposition
            pendingDisposition = nil
            return h
        }
        handler?(.allow)
    }

    /// Drops the response without reading the body.
    func reject() {
        let handler: ((URLSession.ResponseDisposition) -> Void)? = lock.withLock {
            let h = pendingDisposition
            pendingDisposition = nil
            return h
        }
        handler?(.cancel)
        completionBox.resolve(.success(()))
    }

    func cancel() {
        let handler: ((URLSession.ResponseDisposition) -> Void)? = lock.withLock {
            let h = pendingDisposition
            pendingDisposition = nil
            sink = nil
            return h
        }
        handler?(.cancel)
        task.cancel()
    }

    /// Waits until the body is complete (or the writer filled its range).
    func completion() async throws {
        try await withTaskCancellationHandler {
            try await completionBox.value()
        } onCancel: {
            self.cancel()
        }
    }

    // MARK: Delegate entry points (called on the session's serial delegate queue)

    func didReceive(response: URLResponse, disposition: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let blocked = blockedRedirect {
            disposition(.cancel)
            responseBox.resolve(.failure(blocked))
            completionBox.resolve(.failure(blocked))
            return
        }
        guard let http = response as? HTTPURLResponse else {
            disposition(.cancel)
            let e = DownloadError(.invalidResponse, "The server did not send an HTTP response.")
            responseBox.resolve(.failure(e))
            completionBox.resolve(.failure(e))
            return
        }
        lock.withLock { pendingDisposition = disposition }
        responseBox.resolve(.success(http))
    }

    func didReceive(data: Data) {
        let writer: RangeWriter? = lock.withLock { stoppedAtLimit ? nil : sink }
        guard let writer else { return }
        do {
            if try writer.write(data) {
                throttle(after: data.count)
                lock.withLock {
                    stoppedAtLimit = true
                    sink = nil
                }
                task.cancel()
                completionBox.resolve(.success(()))
                return
            }
        } catch {
            lock.withLock {
                failure = error
                sink = nil
            }
            task.cancel()
            completionBox.resolve(.failure(error))
            return
        }
        throttle(after: data.count)
    }

    /// Applies speed limits by holding this download's serial delegate queue. While it is held URLSession
    /// stops reading, the socket buffer fills and TCP flow control slows the server down. The wait is
    /// sliced so a pause or cancel takes effect within ~50 ms.
    private func throttle(after bytes: Int) {
        var delay: TimeInterval = 0
        for limiter in limiters { delay = max(delay, limiter.consume(bytes)) }
        guard delay > 0.002 else { return }
        let deadline = Date().addingTimeInterval(delay)
        while Date() < deadline {
            if task.state == .canceling || lock.withLock({ sink == nil }) { return }
            Thread.sleep(forTimeInterval: min(0.05, deadline.timeIntervalSinceNow))
        }
    }

    func didComplete(error: Error?) {
        let (limitReached, storedFailure) = lock.withLock { (stoppedAtLimit, failure) }
        if limitReached { completionBox.resolve(.success(())); return }
        if let storedFailure { completionBox.resolve(.failure(storedFailure)); responseBox.resolve(.failure(storedFailure)); return }
        if let blockedRedirect { responseBox.resolve(.failure(blockedRedirect)); completionBox.resolve(.failure(blockedRedirect)); return }
        if let error {
            let mapped: Error = (error as? URLError)?.code == .cancelled ? CancellationError() : DownloadError.from(error)
            responseBox.resolve(.failure(mapped))
            completionBox.resolve(.failure(mapped))
        } else {
            responseBox.resolve(.failure(DownloadError(.invalidResponse, "The connection closed before a response arrived.")))
            completionBox.resolve(.success(()))
        }
    }
}

/// Owns one URLSession per engine run. The session's delegate is this object; `invalidate()` breaks
/// the session → delegate retain cycle.
final class TransferSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var session: URLSession!
    private let lock = NSLock()
    private var transfers: [Int: DataTransfer] = [:]
    private let originalURL: URL
    private let credentials: BasicCredentials?
    private let redirectPolicy: RedirectPolicy
    private let limiters: [BandwidthLimiter]
    private let invalidated = OneShot<Void>()

    init(originalURL: URL, credentials: BasicCredentials?, redirectPolicy: RedirectPolicy,
         readTimeout: TimeInterval, maxConnectionsPerHost: Int, limiters: [BandwidthLimiter]) {
        self.originalURL = originalURL
        self.credentials = credentials
        self.redirectPolicy = redirectPolicy
        self.limiters = limiters
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil          // never send or store cookies
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = readTimeout   // idle timeout between packets
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.httpMaximumConnectionsPerHost = max(1, maxConnectionsPerHost)
        config.waitsForConnectivity = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.oledownloadmanager.transfer"
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    func makeTransfer(_ request: URLRequest) -> DataTransfer {
        let task = session.dataTask(with: request)
        let transfer = DataTransfer(task: task, limiters: limiters)
        lock.withLock { transfers[task.taskIdentifier] = transfer }
        return transfer
    }

    private func transfer(for task: URLSessionTask) -> DataTransfer? {
        lock.withLock { transfers[task.taskIdentifier] }
    }

    /// Cancels everything and waits until the delegate queue has drained.
    func invalidateAndWait() async {
        session.invalidateAndCancel()
        _ = try? await invalidated.value()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        invalidated.resolve(.success(()))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let t = transfer(for: dataTask) else { completionHandler(.cancel); return }
        t.didReceive(response: response, disposition: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        transfer(for: dataTask)?.didReceive(data: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let t = lock.withLock { transfers.removeValue(forKey: task.taskIdentifier) }
        t?.didComplete(error: error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let t = transfer(for: task), let target = request.url else { completionHandler(nil); return }
        t.redirectCount += 1
        let from = task.currentRequest?.url ?? originalURL
        if let problem = redirectPolicy.check(from: from, to: target, originalURL: originalURL, redirectCount: t.redirectCount) {
            t.blockedRedirect = problem
            completionHandler(nil)
            return
        }
        var next = request
        // Never forward credentials or custom secrets to a different host.
        if target.host?.lowercased() != originalURL.host?.lowercased() {
            for header in (next.allHTTPHeaderFields ?? [:]).keys where Redactor.isSensitiveHeader(header) {
                next.setValue(nil, forHTTPHeaderField: header)
            }
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        // TLS server trust: always use the system's default evaluation. Never bypass it.
        if method == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let isHTTPAuth = method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest
        let sameHost = challenge.protectionSpace.host.lowercased() == originalURL.host?.lowercased()
        if isHTTPAuth, sameHost, challenge.previousFailureCount == 0, let credentials {
            completionHandler(.useCredential, URLCredential(user: credentials.user, password: credentials.password, persistence: .none))
            return
        }
        // No (more) credentials: let the 401 response come through so we can report it once.
        completionHandler(.performDefaultHandling, nil)
    }
}
