import Foundation

/// Native-messaging style framing: a 4-byte little-endian length followed by UTF-8 JSON.
/// Used both on the browser's stdin/stdout pipe and on the app's Unix socket.
public enum MessageFraming {
    public enum FramingError: Error, Equatable { case endOfStream, tooLarge(UInt32), ioError(Int32), timedOut }

    public static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).littleEndian
        var out = Data(bytes: &length, count: 4)
        out.append(payload)
        return out
    }

    /// Reads exactly one frame from a file descriptor. Blocks; use socket timeouts to bound it.
    public static func readFrame(fd: Int32, maxBytes: Int = BrowserProtocol.maxMessageBytes) throws(FramingError) -> Data {
        let header = try readExactly(fd: fd, count: 4)
        let length = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard length <= UInt32(maxBytes) else { throw .tooLarge(length) }
        if length == 0 { return Data() }
        return try readExactly(fd: fd, count: Int(length))
    }

    public static func writeFrame(fd: Int32, payload: Data) throws(FramingError) {
        let data = frame(payload)
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { buf in write(fd, buf.baseAddress!.advanced(by: offset), data.count - offset) }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw .timedOut }
                throw .ioError(errno)
            }
            offset += n
        }
    }

    static func readExactly(fd: Int32, count: Int) throws(FramingError) -> Data {
        var buffer = Data(count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { buf in read(fd, buf.baseAddress!.advanced(by: offset), count - offset) }
            if n == 0 { throw .endOfStream }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw .timedOut }
                throw .ioError(errno)
            }
            offset += n
        }
        return buffer
    }
}
