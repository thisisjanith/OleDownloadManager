import Foundation

/// Versioned JSON protocol shared by the browser extensions, the native messaging host and the app.
/// See ARCHITECTURE.md › Browser integration for the full message reference.
public enum BrowserProtocol {
    public static let version = 1
    /// Hard cap for any single message in either direction.
    public static let maxMessageBytes = 64 * 1024
    public static let maxURLLength = 8 * 1024
    public static let maxFileNameLength = 1024
    public static let maxIDLength = 64

    /// Extension identities allowed to talk to the app. The browsers enforce the same list
    /// through the native messaging host manifests (`allowed_origins` / `allowed_extensions`).
    public static let chromeExtensionIDs: Set<String> = ["adndpcefokbkijmccnbhfkhllcpedgfj"]
    public static let firefoxExtensionIDs: Set<String> = ["oledownloadmanager@oledownloadmanager.app"]

    public static func isAllowedOrigin(_ origin: String) -> Bool {
        if origin.hasPrefix("chrome-extension://") {
            let id = origin.dropFirst("chrome-extension://".count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return chromeExtensionIDs.contains(id)
        }
        return firefoxExtensionIDs.contains(origin)
    }
}

public enum BrowserMessageType: String, Codable, Sendable {
    // Requests (extension → app)
    case hello, getStatus, addDownload
    // Responses (app → extension)
    case status, downloadAccepted, downloadRejected, error

    public var isRequest: Bool { self == .hello || self == .getStatus || self == .addDownload }
}

/// Wire representation. All fields except `v` and `type` are optional on the wire; the validator
/// enforces which ones each message type requires.
public struct BrowserMessage: Codable, Sendable, Equatable {
    public var v: Int
    public var type: BrowserMessageType
    public var id: String?

    // Request fields
    public var url: String?
    public var pageUrl: String?
    public var referrer: String?
    public var fileName: String?
    /// "start", "queue" or "default" (use the app's setting).
    public var mode: String?
    /// "contextMenu", "interception" or "popup".
    public var source: String?
    public var browser: String?
    public var extensionVersion: String?
    /// Added by the native host from the browser-provided caller identity; never trusted from the extension.
    public var origin: String?

    // Response fields
    public var appVersion: String?
    public var connected: Bool?
    public var captureEnabled: Bool?
    public var captureAction: String?
    public var downloadId: String?
    public var reason: String?
    public var message: String?
    public var code: String?

    public init(type: BrowserMessageType, id: String? = nil) {
        self.v = BrowserProtocol.version
        self.type = type
        self.id = id
    }

    public static func error(id: String?, code: String, message: String) -> BrowserMessage {
        var m = BrowserMessage(type: .error, id: id)
        m.code = code
        m.message = message
        return m
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum BrowserProtocolError: Error, Equatable, Sendable, CustomStringConvertible {
    case tooLarge
    case malformedJSON
    case unsupportedVersion(Int)
    case unknownType
    case notARequest
    case invalidField(String)
    case unauthorizedOrigin

    public var code: String {
        switch self {
        case .tooLarge: "tooLarge"
        case .malformedJSON: "malformed"
        case .unsupportedVersion: "unsupportedVersion"
        case .unknownType: "unknownType"
        case .notARequest: "notARequest"
        case .invalidField: "invalidField"
        case .unauthorizedOrigin: "unauthorizedOrigin"
        }
    }

    public var description: String {
        switch self {
        case .tooLarge: "Message exceeds \(BrowserProtocol.maxMessageBytes) bytes."
        case .malformedJSON: "Message is not valid JSON for this protocol."
        case .unsupportedVersion(let v): "Protocol version \(v) is not supported (expected \(BrowserProtocol.version))."
        case .unknownType: "Unknown message type."
        case .notARequest: "Only hello, getStatus and addDownload may be sent to the app."
        case .invalidField(let f): "Invalid or missing field: \(f)."
        case .unauthorizedOrigin: "The calling extension is not authorized."
        }
    }
}

public struct AddDownloadRequest: Sendable, Equatable {
    public enum Mode: String, Sendable { case start, queue, `default` }
    public enum Source: String, Sendable { case contextMenu, interception, popup }

    public var id: String?
    public var url: String
    public var pageURL: String?
    public var referrer: String?
    public var fileName: String?
    public var mode: Mode
    public var source: Source
    public var origin: String
    public var browser: String?
}

public enum BrowserRequest: Sendable, Equatable {
    case hello(id: String?, browser: String?, extensionVersion: String?)
    case getStatus(id: String?)
    case addDownload(AddDownloadRequest)

    public var id: String? {
        switch self {
        case .hello(let id, _, _), .getStatus(let id): id
        case .addDownload(let r): r.id
        }
    }
}

public enum BrowserMessageValidator {
    /// Decodes and validates a request. When `requireOrigin` is true (app side), the message must carry an
    /// origin that the native host added and that is on the allowlist.
    public static func validateRequest(_ data: Data, requireOrigin: Bool) -> Result<BrowserRequest, BrowserProtocolError> {
        guard data.count <= BrowserProtocol.maxMessageBytes else { return .failure(.tooLarge) }
        guard let object = try? JSONSerialization.jsonObject(with: data), let dict = object as? [String: Any] else {
            return .failure(.malformedJSON)
        }
        guard let v = dict["v"] as? Int else { return .failure(.invalidField("v")) }
        guard v == BrowserProtocol.version else { return .failure(.unsupportedVersion(v)) }
        guard let typeString = dict["type"] as? String else { return .failure(.invalidField("type")) }
        guard let type = BrowserMessageType(rawValue: typeString) else { return .failure(.unknownType) }
        guard type.isRequest else { return .failure(.notARequest) }
        guard let message = try? JSONDecoder().decode(BrowserMessage.self, from: data) else { return .failure(.malformedJSON) }

        if let id = message.id, id.count > BrowserProtocol.maxIDLength || !id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) {
            return .failure(.invalidField("id"))
        }
        if let b = message.browser, b.count > 32 { return .failure(.invalidField("browser")) }
        if let ev = message.extensionVersion, ev.count > 32 { return .failure(.invalidField("extensionVersion")) }

        var origin = ""
        if requireOrigin {
            guard let o = message.origin, !o.isEmpty, o.count <= 256 else { return .failure(.unauthorizedOrigin) }
            guard BrowserProtocol.isAllowedOrigin(o) else { return .failure(.unauthorizedOrigin) }
            origin = o
        }

        switch type {
        case .hello:
            return .success(.hello(id: message.id, browser: message.browser, extensionVersion: message.extensionVersion))
        case .getStatus:
            return .success(.getStatus(id: message.id))
        case .addDownload:
            guard let url = message.url, isHTTPURL(url) else { return .failure(.invalidField("url")) }
            if let page = message.pageUrl, !page.isEmpty, page.count > BrowserProtocol.maxURLLength { return .failure(.invalidField("pageUrl")) }
            if let ref = message.referrer, !ref.isEmpty, !isHTTPURL(ref) { return .failure(.invalidField("referrer")) }
            if let name = message.fileName, name.count > BrowserProtocol.maxFileNameLength { return .failure(.invalidField("fileName")) }
            let mode = AddDownloadRequest.Mode(rawValue: message.mode ?? "default")
            guard let mode else { return .failure(.invalidField("mode")) }
            let source = AddDownloadRequest.Source(rawValue: message.source ?? "contextMenu")
            guard let source else { return .failure(.invalidField("source")) }
            return .success(.addDownload(AddDownloadRequest(
                id: message.id, url: url, pageURL: message.pageUrl?.nilIfEmpty, referrer: message.referrer?.nilIfEmpty,
                fileName: message.fileName?.nilIfEmpty, mode: mode, source: source, origin: origin, browser: message.browser)))
        default:
            return .failure(.notARequest)
        }
    }

    static func isHTTPURL(_ s: String) -> Bool {
        guard s.count <= BrowserProtocol.maxURLLength, let c = URLComponents(string: s),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty else { return false }
        return true
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
