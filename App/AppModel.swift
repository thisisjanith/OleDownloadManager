import AppKit
import Observation
import OleDownloadCore
import SwiftUI
import UniformTypeIdentifiers

enum SidebarFilter: Hashable, Identifiable {
    case all, downloading, queued, paused, completed, failed, scheduled, trash
    case category(String)

    var id: String {
        switch self {
        case .category(let c): "category.\(c)"
        default: String(describing: self)
        }
    }

    static let statusFilters: [SidebarFilter] = [.all, .downloading, .queued, .paused, .completed, .failed, .scheduled, .trash]

    var title: String {
        switch self {
        case .all: "All Downloads"
        case .downloading: "Downloading"
        case .queued: "Queued"
        case .paused: "Paused"
        case .completed: "Completed"
        case .failed: "Failed"
        case .scheduled: "Scheduled"
        case .trash: "Trash"
        case .category(let id): FileCategory.defaults.first { $0.id == id }?.name ?? id
        }
    }

    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .downloading: "arrow.down.circle"
        case .queued: "list.number"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .scheduled: "calendar.badge.clock"
        case .trash: "trash"
        case .category: "folder"
        }
    }

    @MainActor
    func matches(_ item: DownloadItem) -> Bool {
        let r = item.record
        if self == .trash { return r.isTrashed }
        if r.isTrashed { return false }
        switch self {
        case .all: return true
        case .downloading: return r.state.isActive
        case .queued: return (r.state == .queued && !r.isScheduled) || r.state == .waitingForDestination
        case .paused: return r.state == .paused || r.state == .interrupted
        case .completed: return r.state == .completed
        case .failed: return r.state == .failed || r.state == .canceled
        case .scheduled: return r.isScheduled
        case .trash: return false
        case .category(let id): return r.categoryID == id
        }
    }
}

enum SortOption: String, CaseIterable, Identifiable {
    case queueOrder, dateAdded, name, size, progress, status
    var id: String { rawValue }
    var title: String {
        switch self {
        case .queueOrder: "Queue Order"
        case .dateAdded: "Date Added"
        case .name: "Name"
        case .size: "Size"
        case .progress: "Progress"
        case .status: "Status"
        }
    }
}

/// Draft for the Add Download sheet.
struct AddDownloadDraft: Identifiable {
    let id = UUID()
    var urlText: String
    var origin: DownloadOrigin
}

/// Pending confirmation shown by the main window.
enum PendingConfirmation: Identifiable {
    case cancel([UUID])
    case removeActive([UUID])
    case deletePermanently([UUID])
    case emptyTrash

    var id: String {
        switch self {
        case .cancel(let ids): "cancel-\(ids)"
        case .removeActive(let ids): "remove-\(ids)"
        case .deletePermanently(let ids): "delete-\(ids)"
        case .emptyTrash: "emptyTrash"
        }
    }
}

/// App-level state shared by every window. Holds no networking logic; it forwards to the coordinator.
@MainActor
@Observable
final class AppModel {
    let coordinator: DownloadCoordinator
    let bridge = BrowserBridgeService()
    let notifications: NotificationService
    let isUITesting: Bool

    var sidebar: SidebarFilter = .all
    var searchText = ""
    var sort: SortOption = .dateAdded
    var sortAscending = false
    var selection: Set<UUID> = []
    var showInspector = true
    var addDraft: AddDownloadDraft?
    var confirmation: PendingConfirmation?
    var alertMessage: String?
    /// UI-test fixture only: what "Open" / "Reveal" would have opened.
    var lastWorkspaceAction = ""

    init() {
        let env = ProcessInfo.processInfo.environment
        isUITesting = ProcessInfo.processInfo.arguments.contains("-UITestMode")
        let dataDir = env["OLEDM_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? DownloadRepository.defaultDirectory()

        let repository: DownloadRepository
        do {
            repository = try DownloadRepository(directory: dataDir)
        } catch {
            // The database could not be opened (e.g. a newer schema). Keep the app usable with an
            // in-memory store and tell the user instead of crashing.
            repository = (try? DownloadRepository(database: .inMemory()))!
            alertMessage = "The download database could not be opened: \(error). History will not be saved this session."
        }
        if isUITesting, let downloads = env["OLEDM_DOWNLOAD_DIR"], repository.loadSettings() == nil {
            // Explicit UI-test fixture: isolated download folder and fast retries.
            var s = AppSettings()
            s.defaultDirectoryPath = downloads
            s.showNotifications = false
            s.retryBaseDelay = 0.5
            s.retryMaxDelay = 1
            s.maxRetries = Int(env["OLEDM_MAX_RETRIES"] ?? "") ?? 0
            s.showMenuBarItem = false
            repository.saveSettings(s)
        }
        var environment = CoordinatorEnvironment(store: repository, secrets: isUITesting ? InMemorySecretStore() : KeychainSecretStore())
        if isUITesting { environment.minimumSegmentSize = 64 * 1024 }
        coordinator = DownloadCoordinator(environment: environment)
        notifications = NotificationService(enabled: !isUITesting)
        coordinator.onEvent = { [weak self] event in self?.handle(event) }
    }

    func start() {
        coordinator.start()
        if !isUITesting { bridge.start(coordinator: coordinator) }
        applyAppearance()
    }

    var settings: AppSettings { coordinator.settings }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var s = coordinator.settings
        change(&s)
        coordinator.updateSettings(s)
        applyAppearance()
    }

    func applyAppearance() {
        switch settings.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: List

    var visibleItems: [DownloadItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = coordinator.items.filter { item in
            guard sidebar.matches(item) else { return false }
            guard !query.isEmpty else { return true }
            return item.record.fileName.lowercased().contains(query) || item.host.lowercased().contains(query)
        }
        return filtered.sorted(by: comparator)
    }

    private var comparator: (DownloadItem, DownloadItem) -> Bool {
        let asc = sortAscending
        func order<T: Comparable>(_ a: T, _ b: T) -> Bool { asc ? a < b : a > b }
        switch sort {
        case .queueOrder: return { $0.record.queuePosition < $1.record.queuePosition }
        case .dateAdded: return { order($0.record.createdAt, $1.record.createdAt) }
        case .name: return { order($0.record.fileName.localizedLowercase, $1.record.fileName.localizedLowercase) }
        case .size: return { order($0.record.expectedLength ?? -1, $1.record.expectedLength ?? -1) }
        case .progress: return { order($0.record.progressFraction ?? -1, $1.record.progressFraction ?? -1) }
        case .status: return { order($0.record.state.label, $1.record.state.label) }
        }
    }

    func count(for filter: SidebarFilter) -> Int { coordinator.items.lazy.filter { filter.matches($0) }.count }

    var selectedItems: [DownloadItem] { coordinator.items.filter { selection.contains($0.id) } }

    // MARK: Adding

    func presentAdd(urlText: String = "", origin: DownloadOrigin = .user) {
        addDraft = AddDownloadDraft(urlText: urlText, origin: origin)
    }

    /// Paste: one or more URLs from the clipboard. A single URL opens the Add sheet prefilled.
    func pasteURLs() {
        let text = NSPasteboard.general.string(forType: .string) ?? NSPasteboard.general.string(forType: .URL) ?? ""
        handleDropped(text: text, origin: .paste)
    }

    func handleDropped(urls: [URL], origin: DownloadOrigin) {
        handleDropped(text: urls.map(\.absoluteString).joined(separator: "\n"), origin: origin)
    }

    func handleDropped(text: String, origin: DownloadOrigin) {
        let candidates = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let valid = candidates.compactMap { try? URLValidator.validate($0, assumeHTTPSIfMissingScheme: false) }
        if valid.count > 1 {
            var added = 0
            for v in valid {
                var request = NewDownloadRequest(url: v.url)
                request.origin = origin
                request.action = settings.defaultAddAction
                if case .success = coordinator.add(request) { added += 1 }
            }
            if added < valid.count { alertMessage = "\(valid.count - added) link(s) were already in the list and were skipped." }
        } else {
            presentAdd(urlText: valid.first?.url.absoluteString ?? candidates.first ?? "", origin: origin)
        }
    }

    // MARK: Actions on selection

    func startOrResume(_ ids: [UUID]) { coordinator.start(ids) }
    func pause(_ ids: [UUID]) { coordinator.pause(ids) }
    func retry(_ ids: [UUID]) { coordinator.retry(ids) }

    func togglePause(_ ids: [UUID]) {
        let items = ids.compactMap { coordinator.item($0) }
        if items.contains(where: { $0.state.canPause }) {
            pause(items.filter { $0.state.canPause }.map(\.id))
        } else {
            startOrResume(items.filter { $0.state.canResume || $0.state == .queued || $0.state == .failed }.map(\.id))
        }
    }

    /// Asks whether to keep partial data when it is worth keeping (resumable progress exists).
    func requestCancel(_ ids: [UUID]) {
        let items = ids.compactMap { coordinator.item($0) }.filter { $0.state.canCancel }
        guard !items.isEmpty else { return }
        if items.contains(where: { $0.record.bytesReceived > 0 && $0.record.supportsRanges == true }) {
            confirmation = .cancel(items.map(\.id))
        } else {
            coordinator.cancel(items.map(\.id), deletePartialData: true)
        }
    }

    /// Delete key / Remove: active items need confirmation; everything goes to Trash first.
    func requestRemove(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        if sidebar == .trash {
            confirmation = .deletePermanently(ids)
        } else if ids.contains(where: { coordinator.item($0)?.state.isActive == true }) {
            confirmation = .removeActive(ids)
        } else {
            coordinator.moveToTrash(ids)
            selection.subtract(ids)
        }
    }

    // MARK: Finder

    func open(_ item: DownloadItem) {
        guard let url = item.record.finalFileURL, item.state == .completed else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            alertMessage = "“\(url.lastPathComponent)” is no longer at its download location."
            return
        }
        if isUITesting { lastWorkspaceAction = "open:\(url.lastPathComponent)"; return }
        NSWorkspace.shared.open(url)   // Gatekeeper still checks quarantined files; we never bypass it.
    }

    func reveal(_ item: DownloadItem) {
        if let url = item.record.finalFileURL, FileManager.default.fileExists(atPath: url.path) {
            if isUITesting { lastWorkspaceAction = "reveal:\(url.lastPathComponent)"; return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            openFolder(item)
        }
    }

    func openFolder(_ item: DownloadItem) {
        let folder = item.record.finalFileURL?.deletingLastPathComponent() ?? item.record.destinationDirectory
        if isUITesting { lastWorkspaceAction = "folder:\(folder.lastPathComponent)"; return }
        NSWorkspace.shared.open(folder)
    }

    func copySourceURL(_ items: [DownloadItem]) {
        copy(items.map(\.record.sourceURL.absoluteString).joined(separator: "\n"))
    }

    func copyFilePath(_ items: [DownloadItem]) {
        copy(items.compactMap { $0.record.finalFileURL?.path ?? $0.record.destinationDirectory.appendingPathComponent($0.record.fileName).path }.joined(separator: "\n"))
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    func chooseFolder(startingAt: URL?) -> URL? {
        // UI-test fixture: NSOpenPanel cannot be driven reliably, so tests supply the folder.
        if isUITesting, let path = ProcessInfo.processInfo.environment["OLEDM_CHOOSE_FOLDER"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where downloaded files are saved. External drives are supported."
        panel.directoryURL = startingAt
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: Events

    private func handle(_ event: CoordinatorEvent) {
        guard settings.showNotifications else { return }
        switch event {
        case .completed(let id, let name, _):
            notifications.post(title: "Download complete", body: name, id: id)
        case .failed(let id, let name, let message):
            notifications.post(title: "Download failed", body: "\(name): \(message)", id: id)
        }
    }
}

/// Shared formatting so sizes, speeds and times look the same everywhere.
enum Format {
    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    @MainActor
    static func progressLine(_ item: DownloadItem) -> String {
        let r = item.record
        let received = bytes(r.bytesReceived)
        let size = r.expectedLength.map { "\(received) of \(bytes($0))" } ?? received
        switch r.state {
        case .downloading:
            var parts = [size, speed(item.smoothedSpeed)]
            if let eta = item.eta { parts.append("\(duration(eta)) left") }
            return parts.joined(separator: " — ")
        case .connecting: return "Connecting to \(item.host)…"
        case .verifying: return "Verifying \(r.expectedLength.map(bytes) ?? received)…"
        case .completed: return r.expectedLength.map(bytes) ?? received
        case .retrying:
            if let next = item.nextRetryAt { return "Retrying in \(duration(max(0, next.timeIntervalSinceNow))) — \(r.lastError?.message ?? "")" }
            return "Retrying…"
        case .failed: return r.lastError?.message ?? "Failed"
        case .waitingForDestination: return r.lastError?.message ?? "Waiting for the destination folder"
        case .queued:
            if let at = r.scheduledAt, at > Date() { return "Starts \(at.formatted(date: .abbreviated, time: .shortened))" }
            return r.bytesReceived > 0 ? "\(size) — waiting" : "Waiting in queue"
        case .paused, .interrupted:
            let resumable = r.supportsRanges == true ? "" : (r.bytesReceived > 0 ? " — will restart (server can't resume)" : "")
            return size + resumable
        case .canceled: return "Canceled"
        }
    }

    static func icon(forFileName name: String) -> NSImage {
        let ext = (name as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}
