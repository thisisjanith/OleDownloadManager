import Foundation

public enum DestinationAvailability: Equatable, Sendable {
    case available
    /// The folder (or the volume it lives on) is not present. Never fall back to another path.
    case unavailable(String)
    case notWritable(String)
}

/// Resolves and checks download destinations, including folders on external volumes.
public struct DestinationManager: Sendable {
    public static let partialFolderName = ".oledownload-partial"

    public init() {}

    public static func systemDownloadsDirectory() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Default directory from settings. A bookmark (if any) is resolved first so a renamed or
    /// re-mounted folder is still found; otherwise the stored path is used.
    public func defaultDirectory(settings: AppSettings) -> URL {
        if let bookmark = settings.defaultDirectoryBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url
            }
        }
        if let path = settings.defaultDirectoryPath, !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return Self.systemDownloadsDirectory()
    }

    public static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: [.volumeUUIDStringKey], relativeTo: nil)
    }

    /// The volume UUID of an existing path, used to detect that an external drive was swapped.
    public func volumeUUID(of url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    /// Checks that `directory` exists, is a writable directory and (if known) still lives on the same volume.
    /// This never creates the directory: creating a missing `/Volumes/Drive/...` path would silently
    /// write to the startup disk instead of the unplugged drive.
    public func availability(of directory: URL, expectedVolumeUUID: String? = nil) -> DestinationAvailability {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir) else {
            if isOnUnmountedVolume(directory) {
                return .unavailable("The drive “\(volumeName(of: directory) ?? "?")” is not connected.")
            }
            return .unavailable("The folder “\(directory.lastPathComponent)” does not exist.")
        }
        guard isDir.boolValue else { return .unavailable("“\(directory.lastPathComponent)” is not a folder.") }
        if let expectedVolumeUUID, let actual = volumeUUID(of: directory), actual != expectedVolumeUUID {
            return .unavailable("The folder is on a different drive than when the download was added.")
        }
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            return .notWritable("OleDownloadManager cannot write to “\(directory.lastPathComponent)”.")
        }
        return .available
    }

    func isOnUnmountedVolume(_ url: URL) -> Bool {
        let comps = url.standardizedFileURL.pathComponents
        guard comps.count >= 3, comps[1] == "Volumes" else { return false }
        return !FileManager.default.fileExists(atPath: "/Volumes/\(comps[2])")
    }

    func volumeName(of url: URL) -> String? {
        let comps = url.standardizedFileURL.pathComponents
        return comps.count >= 3 && comps[1] == "Volumes" ? comps[2] : nil
    }

    /// Final folder for a download: the root, or root/<Category> when organizing by category.
    /// The category sub-folder is created only inside an existing root.
    public func resolvedDirectory(root: URL, categoryID: String, settings: AppSettings) throws -> URL {
        guard settings.organizeByCategory,
              let category = settings.categories.first(where: { $0.id == categoryID }) else { return root }
        let folder = FileNameSanitizer.sanitize(category.folderName, fallback: "Other")
        return try ensureSubdirectory(of: root, named: folder)
    }

    /// Where partial data is written. By default a hidden folder inside the destination, so data
    /// stays on the destination volume and finalization is an atomic rename.
    public func partialDirectory(for destination: URL, settings: AppSettings) throws -> URL {
        if let custom = settings.customTemporaryDirectoryPath, !custom.isEmpty {
            let root = URL(fileURLWithPath: custom, isDirectory: true)
            guard availability(of: root) == .available else {
                throw DownloadError(.destinationUnavailable, "The temporary folder “\(root.lastPathComponent)” is not available.")
            }
            return root
        }
        return try ensureSubdirectory(of: destination, named: Self.partialFolderName)
    }

    public func ensureSubdirectory(of root: URL, named name: String) throws -> URL {
        guard availability(of: root) == .available else {
            throw DownloadError(.destinationUnavailable, "The destination folder “\(root.lastPathComponent)” is not available.")
        }
        let sub = root.appendingPathComponent(name, isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: sub.path, isDirectory: &isDir) {
            guard isDir.boolValue else { throw DownloadError(.fileSystem, "“\(name)” exists but is not a folder.") }
            return sub
        }
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        return sub
    }

    /// Removes the hidden partial folder when it is empty.
    public func cleanUpPartialDirectory(_ dir: URL) {
        guard dir.lastPathComponent == Self.partialFolderName,
              let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              contents.filter({ $0 != ".DS_Store" }).isEmpty else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}

public enum DiskSpace {
    /// Free bytes on the volume containing `url` (which must exist).
    public static func available(at url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values.volumeAvailableCapacity.map(Int64.init)
    }

    /// Space still needed to finish a download, with headroom for file system overhead.
    public static func required(expectedLength: Int64, alreadyReceived: Int64) -> Int64 {
        let remaining = max(0, expectedLength - alreadyReceived)
        let headroom = max(16 * 1024 * 1024, remaining / 100)
        return remaining + headroom
    }

    /// Returns an error when the volume is known to be too small; unknown sizes never fail.
    public static func check(directory: URL, expectedLength: Int64?, alreadyReceived: Int64, availableOverride: Int64? = nil) -> DownloadError? {
        guard let expectedLength, expectedLength > 0, let free = availableOverride ?? available(at: directory) else { return nil }
        let needed = required(expectedLength: expectedLength, alreadyReceived: alreadyReceived)
        guard free < needed else { return nil }
        let f = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        let n = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
        return DownloadError(.diskFull, "Not enough free space: \(n) needed, \(f) available on the destination disk.")
    }
}
