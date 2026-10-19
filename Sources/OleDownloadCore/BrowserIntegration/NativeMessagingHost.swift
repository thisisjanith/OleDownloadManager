import Foundation
import OleBrowserBridge

/// Runs the app side of the browser bridge: a private Unix-domain socket that the native messaging
/// host (launched by the browser) connects to. Each request is validated by the coordinator.
@MainActor
@Observable
public final class BrowserBridgeService {
    public private(set) var isListening = false
    public private(set) var lastError: String?
    @ObservationIgnored private var server: IPCServer?

    public init() {}

    public func start(coordinator: DownloadCoordinator, socketPath: String = IPCPaths.defaultSocketPath()) {
        guard server == nil else { return }
        let server = IPCServer(path: socketPath) { [weak coordinator] data in
            await MainActor.run {
                coordinator?.handleBrowserMessage(data)
                    ?? ((try? BrowserMessage.error(id: nil, code: "unavailable", message: "The app is shutting down.").encoded()) ?? Data())
            }
        }
        do {
            try server.start()
            self.server = server
            isListening = true
            lastError = nil
        } catch {
            lastError = String(describing: error)
            AppLog.browser.error("IPC server failed: \(String(describing: error), privacy: .public)")
        }
    }

    public func stop() {
        server?.stop()
        server = nil
        isListening = false
    }
}

/// Writes and removes the native messaging host manifests that let Chrome-family browsers and
/// Firefox launch `OleNativeHost`. Nothing is installed without an explicit user action.
public struct NativeHostInstaller: Sendable {
    public static let hostName = "com.oledownloadmanager.native"

    public enum Browser: String, CaseIterable, Sendable, Identifiable {
        case chrome, chromium, brave, edge, firefox
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .chrome: "Google Chrome"
            case .chromium: "Chromium"
            case .brave: "Brave"
            case .edge: "Microsoft Edge"
            case .firefox: "Firefox"
            }
        }
        /// Directory (relative to ~/Library/Application Support) where the browser looks for host manifests.
        var manifestDirectory: String {
            switch self {
            case .chrome: "Google/Chrome/NativeMessagingHosts"
            case .chromium: "Chromium/NativeMessagingHosts"
            case .brave: "BraveSoftware/Brave-Browser/NativeMessagingHosts"
            case .edge: "Microsoft Edge/NativeMessagingHosts"
            case .firefox: "Mozilla/NativeMessagingHosts"
            }
        }
        /// The browser's own support folder; used to detect whether it is installed.
        var profileDirectory: String { (manifestDirectory as NSString).deletingLastPathComponent }
        public var isFirefox: Bool { self == .firefox }
    }

    public enum Status: Equatable, Sendable {
        case browserNotFound
        case notInstalled
        case installed
        /// A manifest exists but points to a different or missing executable.
        case stale(String)
    }

    let applicationSupport: URL

    public init(applicationSupport: URL? = nil) {
        self.applicationSupport = applicationSupport
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    public func manifestURL(for browser: Browser) -> URL {
        applicationSupport.appendingPathComponent(browser.manifestDirectory, isDirectory: true)
            .appendingPathComponent("\(Self.hostName).json")
    }

    public func manifest(for browser: Browser, hostPath: String) -> [String: Any] {
        var m: [String: Any] = [
            "name": Self.hostName,
            "description": "OleDownloadManager browser integration",
            "path": hostPath,
            "type": "stdio",
        ]
        if browser.isFirefox {
            m["allowed_extensions"] = Array(BrowserProtocol.firefoxExtensionIDs).sorted()
        } else {
            m["allowed_origins"] = BrowserProtocol.chromeExtensionIDs.sorted().map { "chrome-extension://\($0)/" }
        }
        return m
    }

    public func status(for browser: Browser, hostPath: String) -> Status {
        let url = manifestURL(for: browser)
        guard let data = try? Data(contentsOf: url) else {
            let profile = applicationSupport.appendingPathComponent(browser.profileDirectory)
            return FileManager.default.fileExists(atPath: profile.path) ? .notInstalled : .browserNotFound
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let path = json["path"] as? String else {
            return .stale("The manifest is unreadable.")
        }
        if path != hostPath { return .stale("Points to \(path).") }
        if !FileManager.default.isExecutableFile(atPath: path) { return .stale("The host executable is missing.") }
        return .installed
    }

    public func install(for browser: Browser, hostPath: String) throws {
        let url = manifestURL(for: browser)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: manifest(for: browser, hostPath: hostPath), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    public func uninstall(for browser: Browser) throws {
        let url = manifestURL(for: browser)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
