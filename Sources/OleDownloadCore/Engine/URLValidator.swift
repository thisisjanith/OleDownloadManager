import Foundation

public enum URLValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case empty
    case malformed
    case unsupportedScheme(String)
    case missingHost
    case tooLong

    public var description: String {
        switch self {
        case .empty: "Enter a URL."
        case .malformed: "This doesn't look like a valid URL."
        case .unsupportedScheme(let s): "The “\(s)” scheme is not supported. Use an http or https URL."
        case .missingHost: "The URL has no host name."
        case .tooLong: "The URL is too long."
        }
    }
}

public struct ValidatedURL: Sendable, Equatable {
    /// The URL with any embedded user:password removed.
    public var url: URL
    /// Credentials that were embedded in the URL (moved out so they are never persisted in plain text).
    public var embeddedUser: String?
    public var embeddedPassword: String?
}

public enum URLValidator {
    public static let maxLength = 8 * 1024

    /// Accepts only absolute http/https URLs with a host. Trims whitespace and adds nothing implicitly
    /// except an `https://` scheme when the user typed a bare host such as `example.com/file.zip`.
    public static func validate(_ raw: String, assumeHTTPSIfMissingScheme: Bool = true) throws(URLValidationError) -> ValidatedURL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        guard trimmed.utf8.count <= maxLength else { throw .tooLong }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw .malformed }

        // Spaces are common in pasted links; encode them rather than rejecting the URL.
        var candidate = trimmed.replacingOccurrences(of: " ", with: "%20")
        if assumeHTTPSIfMissingScheme, !candidate.contains("://"), looksLikeBareHost(candidate) {
            candidate = "https://" + candidate
        }
        guard var components = URLComponents(string: candidate) else { throw .malformed }
        guard let scheme = components.scheme?.lowercased() else { throw .malformed }
        guard scheme == "http" || scheme == "https" else { throw .unsupportedScheme(scheme) }
        guard candidate.lowercased().hasPrefix(scheme + "://") else { throw .malformed }
        guard let host = components.host, !host.isEmpty else { throw .missingHost }
        guard !host.contains(where: { $0 == "\\" }) else { throw .malformed }
        if let port = components.port, !(1...65535).contains(port) { throw .malformed }

        let user = components.user.map { $0.removingPercentEncoding ?? $0 }
        let password = components.password.map { $0.removingPercentEncoding ?? $0 }
        components.user = nil
        components.password = nil
        components.scheme = scheme
        guard let url = components.url else { throw .malformed }
        return ValidatedURL(url: url, embeddedUser: user, embeddedPassword: password)
    }

    /// "example.com/file.zip" or "localhost:8080/x" (no scheme) → treat as a host.
    /// "mailto:x" or "javascript:x" → a real scheme, which is then rejected.
    static func looksLikeBareHost(_ s: String) -> Bool {
        let hostPart = s.split(separator: "/", maxSplits: 1).first.map(String.init) ?? s
        guard let colon = hostPart.firstIndex(of: ":") else { return hostPart.contains(".") || hostPart == "localhost" }
        let afterColon = hostPart[hostPart.index(after: colon)...]
        return !afterColon.isEmpty && afterColon.allSatisfy(\.isNumber)
    }

    public static func isSupported(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !(url.host ?? "").isEmpty
    }
}

/// Classifies hosts as loopback/private/link-local so redirects from public sites cannot be used
/// to reach services on the user's machine or LAN.
public enum NetworkAddressClassifier {
    public static func isPrivateOrLocal(host rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") { return true }
        if let v4 = parseIPv4(host) { return isPrivateIPv4(v4) }
        if host.contains(":") { return isPrivateIPv6(host) }
        // A plain single-label name ("intranet") usually resolves on the local network.
        if !host.contains(".") { return true }
        return false
    }

    static func parseIPv4(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isNumber), let v = UInt8(p) else { return nil }
            out.append(v)
        }
        return out
    }

    static func isPrivateIPv4(_ a: [UInt8]) -> Bool {
        switch (a[0], a[1]) {
        case (0, _), (10, _), (127, _): return true
        case (169, 254): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (100, 64...127): return true  // carrier-grade NAT
        default: return false
        }
    }

    static func isPrivateIPv6(_ s: String) -> Bool {
        let h = s.split(separator: "%").first.map(String.init) ?? s
        if h == "::1" || h == "::" { return true }
        if h.hasPrefix("fe8") || h.hasPrefix("fe9") || h.hasPrefix("fea") || h.hasPrefix("feb") { return true } // link-local
        if h.hasPrefix("fc") || h.hasPrefix("fd") { return true } // unique local
        if h.hasPrefix("::ffff:"), let v4 = parseIPv4(String(h.dropFirst(7))) { return isPrivateIPv4(v4) }
        return false
    }
}

/// Rules applied to every HTTP redirect. Documented in SECURITY.md.
public struct RedirectPolicy: Sendable {
    public var maxRedirects = 10
    public var allowHTTPSDowngrade = false
    public var blockPublicToPrivate = true

    public init(maxRedirects: Int = 10, allowHTTPSDowngrade: Bool = false, blockPublicToPrivate: Bool = true) {
        self.maxRedirects = maxRedirects
        self.allowHTTPSDowngrade = allowHTTPSDowngrade
        self.blockPublicToPrivate = blockPublicToPrivate
    }

    /// Returns nil if the redirect is acceptable, otherwise the reason it was blocked.
    public func check(from: URL, to: URL, originalURL: URL, redirectCount: Int) -> DownloadError? {
        if redirectCount > maxRedirects {
            return DownloadError(.tooManyRedirects, "The server redirected more than \(maxRedirects) times.")
        }
        guard URLValidator.isSupported(to) else {
            return DownloadError(.unsafeRedirect, "The server redirected to an unsupported location (\(to.scheme ?? "no scheme")).")
        }
        if !allowHTTPSDowngrade, from.scheme?.lowercased() == "https", to.scheme?.lowercased() == "http" {
            return DownloadError(.unsafeRedirect, "The server tried to redirect from a secure (HTTPS) address to an insecure (HTTP) one. The redirect was blocked.")
        }
        if blockPublicToPrivate,
           let originalHost = originalURL.host, !NetworkAddressClassifier.isPrivateOrLocal(host: originalHost),
           let targetHost = to.host, NetworkAddressClassifier.isPrivateOrLocal(host: targetHost) {
            return DownloadError(.unsafeRedirect, "The server tried to redirect to a local or private-network address. The redirect was blocked.")
        }
        return nil
    }
}
