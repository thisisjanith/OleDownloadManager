import Foundation

/// Classified download failure. `isTransient` drives automatic retry decisions.
public struct DownloadError: Error, Sendable, Equatable, Codable, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable {
        case invalidURL, unsupportedScheme, unsafeRedirect, tooManyRedirects
        case dnsFailure, cannotConnect, connectionLost, networkUnavailable, timedOut, tlsFailure
        case authenticationRequired, forbidden, notFound, httpClientError, requestTimeout, rateLimited, serverError
        case invalidResponse, invalidRangeResponse, sourceChanged, sizeMismatch, checksumMismatch
        case diskFull, permissionDenied, destinationUnavailable, fileSystem, partialDataMissing
        case fileExists
        case unknown
    }

    public var kind: Kind
    /// Readable explanation suitable for the UI.
    public var message: String
    /// Technical detail (redacted) for the details inspector and diagnostics.
    public var detail: String?
    public var httpStatus: Int?
    /// Seconds from a Retry-After header, if any.
    public var retryAfter: TimeInterval?

    public init(_ kind: Kind, _ message: String, detail: String? = nil, httpStatus: Int? = nil, retryAfter: TimeInterval? = nil) {
        self.kind = kind
        self.message = message
        self.detail = detail
        self.httpStatus = httpStatus
        self.retryAfter = retryAfter
    }

    public var description: String { "\(kind.rawValue): \(message)" + (detail.map { " (\($0))" } ?? "") }

    /// Errors worth retrying automatically. Permanent failures (bad URL, auth, 404, TLS, disk full...)
    /// are never retried in a loop; the user can still press Retry.
    public var isTransient: Bool {
        switch kind {
        case .dnsFailure, .cannotConnect, .connectionLost, .networkUnavailable, .timedOut,
             .requestTimeout, .rateLimited, .serverError, .invalidResponse:
            true
        default:
            false
        }
    }

    /// The destination volume or folder vanished; the download should wait rather than fail.
    public var isDestinationProblem: Bool { kind == .destinationUnavailable }

    // MARK: Factories

    public static func http(status: Int, retryAfter: TimeInterval? = nil) -> DownloadError {
        switch status {
        case 401:
            return DownloadError(.authenticationRequired,
                "The server requires authentication (HTTP 401). Add a username and password (Basic or Digest authentication) and retry.",
                httpStatus: status)
        case 403:
            return DownloadError(.forbidden,
                "Access was denied (HTTP 403). The link may have expired or may require a signed-in browser session, which OleDownloadManager does not share.",
                httpStatus: status)
        case 404, 410:
            return DownloadError(.notFound, "The file was not found on the server (HTTP \(status)).", httpStatus: status)
        case 408:
            return DownloadError(.requestTimeout, "The server timed out waiting for the request (HTTP 408).", httpStatus: status, retryAfter: retryAfter)
        case 416:
            return DownloadError(.invalidRangeResponse, "The server rejected the requested byte range (HTTP 416).", httpStatus: status)
        case 429:
            return DownloadError(.rateLimited, "The server is rate limiting requests (HTTP 429).", httpStatus: status, retryAfter: retryAfter)
        case 500...599:
            return DownloadError(.serverError, "The server reported an error (HTTP \(status)).", httpStatus: status, retryAfter: retryAfter)
        default:
            return DownloadError(.httpClientError, "The server responded with HTTP \(status).", httpStatus: status)
        }
    }

    /// Maps any thrown error into a classified `DownloadError`.
    public static func from(_ error: Error) -> DownloadError {
        if let e = error as? DownloadError { return e }
        if let e = error as? URLError { return from(urlError: e) }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return from(posix: Int32(ns.code), detail: ns.localizedDescription) }
        if ns.domain == NSCocoaErrorDomain {
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
                return from(posix: Int32(underlying.code), detail: ns.localizedDescription)
            }
            switch ns.code {
            case NSFileWriteOutOfSpaceError:
                return DownloadError(.diskFull, "There is not enough free space on the destination disk.", detail: ns.localizedDescription)
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return DownloadError(.permissionDenied, "OleDownloadManager does not have permission to write to the destination folder.", detail: ns.localizedDescription)
            case NSFileWriteVolumeReadOnlyError:
                return DownloadError(.permissionDenied, "The destination volume is read-only.", detail: ns.localizedDescription)
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return DownloadError(.destinationUnavailable, "The destination folder is not available.", detail: ns.localizedDescription)
            case NSFileWriteFileExistsError:
                return DownloadError(.fileExists, "A file with the same name already exists.", detail: ns.localizedDescription)
            default:
                return DownloadError(.fileSystem, "A file system error occurred.", detail: ns.localizedDescription)
            }
        }
        return DownloadError(.unknown, "An unexpected error occurred.", detail: ns.localizedDescription)
    }

    public static func from(posix code: Int32, detail: String? = nil) -> DownloadError {
        switch code {
        case ENOSPC, EDQUOT:
            return DownloadError(.diskFull, "There is not enough free space on the destination disk.", detail: detail)
        case EACCES, EPERM:
            return DownloadError(.permissionDenied, "OleDownloadManager does not have permission to write to the destination folder.", detail: detail)
        case EROFS:
            return DownloadError(.permissionDenied, "The destination volume is read-only.", detail: detail)
        case ENOENT, ENXIO, ENODEV, EIO, ENOTDIR:
            return DownloadError(.destinationUnavailable, "The destination is not available. If it is on an external drive, reconnect the drive.", detail: detail)
        case EEXIST:
            return DownloadError(.fileExists, "A file with the same name already exists.", detail: detail)
        default:
            return DownloadError(.fileSystem, "A file system error occurred (\(String(cString: strerror(code)))).", detail: detail)
        }
    }

    public static func from(urlError e: URLError) -> DownloadError {
        let detail = "URLError \(e.code.rawValue): \(e.localizedDescription)"
        switch e.code {
        case .cannotFindHost, .dnsLookupFailed:
            return DownloadError(.dnsFailure, "The server's address could not be found. Check the URL and your network connection.", detail: detail)
        case .cannotConnectToHost:
            return DownloadError(.cannotConnect, "Could not connect to the server.", detail: detail)
        case .networkConnectionLost:
            return DownloadError(.connectionLost, "The network connection was lost.", detail: detail)
        case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed, .callIsActive:
            return DownloadError(.networkUnavailable, "The Mac is not connected to the internet.", detail: detail)
        case .timedOut:
            return DownloadError(.timedOut, "The connection timed out.", detail: detail)
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            return DownloadError(.tlsFailure, "A secure connection to the server could not be established. The server's certificate was not accepted; certificate checks are never bypassed.", detail: detail)
        case .badURL, .unsupportedURL:
            return DownloadError(.invalidURL, "The URL is not valid.", detail: detail)
        case .httpTooManyRedirects, .redirectToNonExistentLocation:
            return DownloadError(.tooManyRedirects, "The server redirected too many times or to an invalid location.", detail: detail)
        case .userAuthenticationRequired, .userCancelledAuthentication:
            return DownloadError(.authenticationRequired, "The server requires authentication that was not accepted.", detail: detail)
        case .cannotCreateFile, .cannotOpenFile, .cannotWriteToFile:
            return DownloadError(.fileSystem, "The downloaded data could not be written to disk.", detail: detail)
        case .badServerResponse, .cannotParseResponse, .zeroByteResource, .cannotDecodeRawData, .cannotDecodeContentData:
            return DownloadError(.invalidResponse, "The server sent an invalid response.", detail: detail)
        default:
            return DownloadError(.unknown, "The download failed because of a network error.", detail: detail)
        }
    }
}
