import Foundation

/// Quick look at a URL before downloading: final name, size, type and whether it can resume.
/// Sends one `Range: bytes=0-0` GET and drops the connection as soon as headers arrive.
public struct URLMetadata: Sendable, Equatable {
    public var suggestedFileName: String
    public var totalLength: Int64?
    public var contentType: String?
    public var supportsRanges: Bool
    public var finalURL: URL?
    public var httpStatus: Int
}

public enum MetadataProbe {
    public static func probe(_ url: URL, headers: [String: String] = [:], credentials: BasicCredentials? = nil,
                             timeout: TimeInterval = 15) async throws -> URLMetadata {
        let session = TransferSession(originalURL: url, credentials: credentials, redirectPolicy: RedirectPolicy(),
                                      readTimeout: timeout, maxConnectionsPerHost: 1, limiters: [])
        defer { Task { await session.invalidateAndWait() } }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        for (k, v) in headers where (try? HTTPHeaderValidator.validate(name: k, value: v)) != nil { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.httpShouldHandleCookies = false
        let transfer = session.makeTransfer(request)
        let response = try await transfer.response(timeout: timeout)
        transfer.reject()
        let status = response.statusCode
        guard (200..<300).contains(status) else {
            throw DownloadError.http(status: status, retryAfter: RetryPolicy.parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        }
        var total: Int64?
        var ranges = false
        if status == 206, let cr = ContentRange.parse(response.value(forHTTPHeaderField: "Content-Range")), cr.first == 0 {
            total = cr.completeLength
            ranges = cr.completeLength != nil
        } else if status == 200, response.expectedContentLength >= 0 {
            total = response.expectedContentLength
        }
        let name = FileNameSanitizer.suggestedName(contentDisposition: response.value(forHTTPHeaderField: "Content-Disposition"),
                                                   url: response.url ?? url, mimeType: response.mimeType)
        return URLMetadata(suggestedFileName: name, totalLength: total, contentType: response.mimeType,
                           supportsRanges: ranges, finalURL: response.url, httpStatus: status)
    }
}
