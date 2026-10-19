import Foundation

/// Parsed `Content-Range: bytes first-last/complete` header (RFC 9110 §14.4).
public struct ContentRange: Equatable, Sendable {
    public var first: Int64
    public var last: Int64
    /// nil when the server sent `*` (unknown complete length).
    public var completeLength: Int64?

    public var length: Int64 { last - first + 1 }

    /// Returns nil for anything malformed, including unsatisfied-range form (`bytes */N`).
    public static func parse(_ header: String?) -> ContentRange? {
        guard let header = header?.trimmingCharacters(in: .whitespaces) else { return nil }
        let lower = header.lowercased()
        guard lower.hasPrefix("bytes ") else { return nil }
        let spec = lower.dropFirst("bytes ".count).trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let rangePart = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard rangePart.count == 2,
              let first = parseNonNegative(rangePart[0]),
              let last = parseNonNegative(rangePart[1]),
              last >= first else { return nil }
        var complete: Int64?
        if parts[1] != "*" {
            guard let c = parseNonNegative(parts[1]), c > last else { return nil }
            complete = c
        }
        return ContentRange(first: first, last: last, completeLength: complete)
    }

    private static func parseNonNegative(_ s: Substring) -> Int64? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 19, t.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int64(t)
    }
}

/// Extracts the filename from a Content-Disposition header (RFC 6266 / RFC 5987).
/// `filename*` (with charset) wins over `filename`. The result is NOT sanitized; pass it to `FileNameSanitizer`.
public enum ContentDisposition {
    public static func fileName(from header: String?) -> String? {
        guard let header, !header.isEmpty else { return nil }
        let params = parseParameters(header)
        if let extended = params["filename*"], let decoded = decodeExtendedValue(extended), !decoded.isEmpty {
            return decoded
        }
        if let plain = params["filename"], !plain.isEmpty {
            // Some servers percent-encode plain filenames; decode only if it yields valid UTF-8.
            if plain.contains("%"), let decoded = plain.removingPercentEncoding { return decoded }
            return plain
        }
        return nil
    }

    static func parseParameters(_ header: String) -> [String: String] {
        var result: [String: String] = [:]
        var i = header.startIndex
        // Skip disposition type.
        while i < header.endIndex, header[i] != ";" { i = header.index(after: i) }
        while i < header.endIndex {
            i = header.index(after: i) // skip ';'
            while i < header.endIndex, header[i] == " " || header[i] == "\t" { i = header.index(after: i) }
            var name = ""
            while i < header.endIndex, header[i] != "=", header[i] != ";" { name.append(header[i]); i = header.index(after: i) }
            name = name.trimmingCharacters(in: .whitespaces).lowercased()
            guard i < header.endIndex, header[i] == "=" else { continue }
            i = header.index(after: i)
            while i < header.endIndex, header[i] == " " { i = header.index(after: i) }
            var value = ""
            if i < header.endIndex, header[i] == "\"" {
                i = header.index(after: i)
                while i < header.endIndex, header[i] != "\"" {
                    if header[i] == "\\" {
                        let next = header.index(after: i)
                        if next < header.endIndex { value.append(header[next]); i = header.index(after: next); continue }
                    }
                    value.append(header[i])
                    i = header.index(after: i)
                }
                if i < header.endIndex { i = header.index(after: i) }
                while i < header.endIndex, header[i] != ";" { i = header.index(after: i) }
            } else {
                while i < header.endIndex, header[i] != ";" { value.append(header[i]); i = header.index(after: i) }
                value = value.trimmingCharacters(in: .whitespaces)
            }
            if !name.isEmpty, result[name] == nil { result[name] = value }
        }
        return result
    }

    /// Decodes `charset'lang'percent-encoded` (RFC 5987).
    static func decodeExtendedValue(_ value: String) -> String? {
        let parts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let charset = parts[0].lowercased()
        let encoded = String(parts[2])
        guard let bytes = percentDecodedBytes(encoded) else { return nil }
        switch charset {
        case "utf-8", "utf8": return String(bytes: bytes, encoding: .utf8)
        case "iso-8859-1", "latin1": return String(bytes: bytes, encoding: .isoLatin1)
        default: return nil
        }
    }

    private static func percentDecodedBytes(_ s: String) -> [UInt8]? {
        var out: [UInt8] = []
        var it = Array(s.utf8)[...]
        while let c = it.popFirst() {
            if c == UInt8(ascii: "%") {
                guard let h = it.popFirst(), let l = it.popFirst(),
                      let v = UInt8(String(bytes: [h, l], encoding: .ascii) ?? "", radix: 16) else { return nil }
                out.append(v)
            } else {
                out.append(c)
            }
        }
        return out
    }
}

/// Validators that identify one representation of a resource. Used to make sure resumed or
/// segmented data all comes from the same version of the file.
public struct ResourceValidators: Codable, Sendable, Equatable {
    public var etag: String?
    public var lastModified: String?
    public var contentLength: Int64?

    public init(etag: String? = nil, lastModified: String? = nil, contentLength: Int64? = nil) {
        self.etag = etag
        self.lastModified = lastModified
        self.contentLength = contentLength
    }

    public init(response: HTTPURLResponse, contentLength: Int64?) {
        etag = response.value(forHTTPHeaderField: "ETag")
        lastModified = response.value(forHTTPHeaderField: "Last-Modified")
        self.contentLength = contentLength
    }

    public var hasStrongETag: Bool {
        guard let etag else { return false }
        return !etag.hasPrefix("W/") && etag.hasPrefix("\"")
    }

    /// Value for `If-Range`: a strong ETag, else Last-Modified. Weak ETags are not allowed in If-Range.
    public var ifRangeValue: String? { hasStrongETag ? etag : lastModified }

    /// True when `other` positively identifies a different representation.
    /// Missing validators on either side are treated as "unknown", not as a change.
    public func conflicts(with other: ResourceValidators) -> Bool {
        if let a = etag, let b = other.etag, a != b { return true }
        if let a = lastModified, let b = other.lastModified, a != b { return true }
        if let a = contentLength, let b = other.contentLength, a != b { return true }
        return false
    }
}

/// Validation for user-supplied request headers.
public enum HTTPHeaderValidator {
    /// Headers the engine controls itself and that users may not override.
    static let reserved: Set<String> = [
        "host", "range", "if-range", "content-length", "transfer-encoding", "connection", "accept-encoding",
        "upgrade", "te", "trailer", "keep-alive", "proxy-connection", "expect",
    ]

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case invalidName(String), invalidValue(String), reserved(String)
        public var description: String {
            switch self {
            case .invalidName(let n): "“\(n)” is not a valid header name."
            case .invalidValue(let n): "The value of “\(n)” contains invalid characters."
            case .reserved(let n): "“\(n)” is managed by OleDownloadManager and can't be set manually."
            }
        }
    }

    static let tokenChars = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    public static func validate(name: String, value: String) throws(Problem) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n.count <= 128, n.unicodeScalars.allSatisfy({ tokenChars.contains($0) }) else { throw .invalidName(name) }
        guard !reserved.contains(n.lowercased()) else { throw .reserved(n) }
        guard value.count <= 8192, !value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else { throw .invalidValue(n) }
    }

    /// Parses "Name: value" lines, as typed into the Add Download dialog.
    public static func parse(_ text: String) throws(Problem) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { throw .invalidName(trimmed) }
            let name = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            try validate(name: name, value: value)
            result[name] = value
        }
        return result
    }
}
