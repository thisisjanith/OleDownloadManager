import Foundation

/// Removes secrets from URLs and headers before they reach logs or diagnostics.
public enum Redactor {
    static let sensitiveQueryKeys: Set<String> = [
        "token", "access_token", "id_token", "refresh_token", "auth", "authorization", "key", "api_key", "apikey",
        "password", "pass", "pwd", "secret", "sig", "signature", "session", "sessionid", "sid", "code", "credential",
        "x-amz-signature", "x-amz-credential", "x-amz-security-token", "x-goog-signature", "x-goog-credential",
        "se", "sp", "sv", "st", "skoid", "sktid", "policy", "key-pair-id", "hmac", "jwt",
    ]

    static let sensitiveHeaders: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "x-auth-token", "x-csrf-token",
    ]

    /// Masks user info and the values of sensitive query parameters.
    public static func redact(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "<unparseable URL>" }
        if c.user != nil { c.user = "redacted" }
        if c.password != nil { c.password = nil }
        if let items = c.queryItems {
            c.queryItems = items.map { item in
                let lowered = item.name.lowercased()
                if sensitiveQueryKeys.contains(lowered) || lowered.contains("token") || lowered.contains("sig") || lowered.contains("secret") {
                    return URLQueryItem(name: item.name, value: "REDACTED")
                }
                return item
            }
        }
        c.fragment = nil
        return c.string ?? "<unparseable URL>"
    }

    public static func redact(urlString: String) -> String {
        URL(string: urlString).map(redact) ?? "<invalid URL>"
    }

    public static func isSensitiveHeader(_ name: String) -> Bool {
        sensitiveHeaders.contains(name.lowercased())
    }

    public static func redact(headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { $0[$1.key] = isSensitiveHeader($1.key) ? "REDACTED" : $1.value }
    }
}
