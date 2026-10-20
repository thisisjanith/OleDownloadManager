import Foundation
import Darwin

/// Location of the app's IPC socket.
///
/// The socket lives in the per-user Darwin temporary directory (`confstr(_CS_DARWIN_USER_TEMP_DIR)`),
/// which is private to the user (mode 0700) and short enough for the 104-byte `sun_path` limit.
/// The socket itself is created with mode 0600 and the server additionally checks the peer's uid.
public enum IPCPaths {
    public static let environmentOverride = "OLEDM_IPC_SOCKET_PATH"

    public static func defaultSocketPath() -> String {
        if let override = ProcessInfo.processInfo.environment[environmentOverride], !override.isEmpty {
            return override
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let len = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let tempDir = len > 0
            ? String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : NSTemporaryDirectory()
        return (tempDir as NSString).appendingPathComponent("com.oledownloadmanager.app/ipc.sock")
    }
}

public enum IPCError: Error, Equatable, CustomStringConvertible {
    case pathTooLong
    case socketFailed(Int32)
    case connectFailed(Int32)
    case bindFailed(Int32)
    case insecureDirectory
    case framing(MessageFraming.FramingError)

    public var appNotRunning: Bool {
        if case .connectFailed(let e) = self { return e == ENOENT || e == ECONNREFUSED }
        return false
    }

    public var description: String {
        switch self {
        case .pathTooLong: "IPC socket path is too long."
        case .socketFailed(let e): "socket() failed: \(String(cString: strerror(e)))"
        case .connectFailed(let e): "connect() failed: \(String(cString: strerror(e)))"
        case .bindFailed(let e): "bind() failed: \(String(cString: strerror(e)))"
        case .insecureDirectory: "IPC directory is not owned by the current user or is accessible to others."
        case .framing(let f): "Framing error: \(f)"
        }
    }
}

enum UnixAddress {
    static func make(_ path: String) throws(IPCError) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw .pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }
}

/// Sends one request frame and reads one response frame.
public enum IPCClient {
    public static func send(_ payload: Data, socketPath: String = IPCPaths.defaultSocketPath(), timeout: TimeInterval = 10) throws(IPCError) -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .socketFailed(errno) }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = try UnixAddress.make(socketPath)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { throw .connectFailed(errno) }
        do {
            try MessageFraming.writeFrame(fd: fd, payload: payload)
            return try MessageFraming.readFrame(fd: fd)
        } catch {
            throw .framing(error)
        }
    }
}

/// Minimal Unix-domain-socket server: one request/response per connection.
///
/// Security: directory 0700, socket 0600, peer uid must equal ours, frames capped at
/// `BrowserProtocol.maxMessageBytes`, and each connection gets a short read timeout.
public final class IPCServer: @unchecked Sendable {
    public typealias Handler = @Sendable (Data) async -> Data

    private let path: String
    private let handler: Handler
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.oledownloadmanager.ipc.accept")
    private let lock = NSLock()

    public init(path: String = IPCPaths.defaultSocketPath(), handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public var socketPath: String { path }

    public func start() throws(IPCError) {
        let dir = (path as NSString).deletingLastPathComponent
        try Self.prepareDirectory(dir)
        // Remove a stale socket from a previous run, but only if it is a socket we own.
        var st = stat()
        if lstat(path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() else { throw .insecureDirectory }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .socketFailed(errno) }
        var addr = try UnixAddress.make(path)
        // No umask juggling here: umask is process-wide and would also affect directories other
        // threads create at the same moment. The socket sits in a 0700 directory and is restricted
        // to 0600 right after bind, before listen() accepts any connection.
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { let e = errno; close(fd); throw .bindFailed(e) }
        guard chmod(path, 0o600) == 0 else { let e = errno; close(fd); unlink(path); throw .bindFailed(e) }
        guard listen(fd, 16) == 0 else { let e = errno; close(fd); throw .bindFailed(e) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptPending() }
        src.setCancelHandler { close(fd) }
        lock.withLock {
            listenFD = fd
            source = src
        }
        src.resume()
    }

    public func stop() {
        let src: DispatchSourceRead? = lock.withLock {
            let s = source
            source = nil
            listenFD = -1
            return s
        }
        src?.cancel()
        unlink(path)
    }

    deinit { source?.cancel() }

    static func prepareDirectory(_ dir: String) throws(IPCError) {
        var st = stat()
        if lstat(dir, &st) != 0 {
            guard mkdir(dir, 0o700) == 0 || errno == EEXIST else { throw .bindFailed(errno) }
            guard lstat(dir, &st) == 0 else { throw .bindFailed(errno) }
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else { throw .insecureDirectory }
        if st.st_mode & 0o077 != 0 { chmod(dir, 0o700) }
    }

    private func acceptPending() {
        let fd = lock.withLock { listenFD }
        guard fd >= 0 else { return }
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            handleClient(client)
        }
    }

    private func handleClient(_ client: Int32) {
        // Only the same user may talk to us.
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); return }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let handler = self.handler
        Task.detached {
            defer { close(client) }
            let request: Data
            do {
                request = try MessageFraming.readFrame(fd: client)
            } catch {
                if case MessageFraming.FramingError.tooLarge = error,
                   let reply = try? BrowserMessage.error(id: nil, code: "tooLarge", message: BrowserProtocolError.tooLarge.description).encoded() {
                    try? MessageFraming.writeFrame(fd: client, payload: reply)
                }
                return
            }
            let response = await handler(request)
            try? MessageFraming.writeFrame(fd: client, payload: response)
        }
    }
}
