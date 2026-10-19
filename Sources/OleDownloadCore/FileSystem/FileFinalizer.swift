import Foundation
import CoreServices
import CryptoKit

/// Moves a verified partial file to its final name without ever overwriting an existing file
/// silently, and tags it with quarantine information like a browser download.
public struct FileFinalizer: Sendable {
    public struct QuarantineInfo: Sendable {
        public var sourceURL: URL
        public var pageURL: URL?
        public init(sourceURL: URL, pageURL: URL?) {
            self.sourceURL = sourceURL
            self.pageURL = pageURL
        }
    }

    public init() {}

    /// What happens when the target name is taken. `skip` is resolved before downloading; if a
    /// conflicting file appears while downloading, the new file is kept under a numbered name so no data is lost.
    public func finalize(partial: URL, directory: URL, fileName: String, policy: ConflictPolicy,
                         quarantine: QuarantineInfo?) throws -> URL {
        guard let target = FileNameSanitizer.safeDestination(directory: directory, name: fileName) else {
            throw DownloadError(.fileSystem, "The file name is not valid for the destination folder.")
        }
        if let quarantine { applyQuarantine(to: partial, info: quarantine) }

        if policy == .replace, FileManager.default.fileExists(atPath: target.path) {
            // Recoverable replacement: the old file goes to the Trash.
            try FileManager.default.trashItem(at: target, resultingItemURL: nil)
        }
        let baseName = target.lastPathComponent
        for n in 0..<10_000 {
            let name = n == 0 ? baseName : FileNameSanitizer.numbered(baseName, n)
            let candidate = directory.appendingPathComponent(name, isDirectory: false)
            switch moveExclusive(from: partial, to: candidate) {
            case .success: return candidate
            case .exists: continue
            case .failure(let error): throw error
            }
        }
        throw DownloadError(.fileExists, "Could not find a free file name for “\(baseName)”.")
    }

    enum MoveResult { case success, exists, failure(Error) }

    /// rename(2) with RENAME_EXCL: atomic and never replaces an existing file.
    /// Falls back to a copy when the partial file lives on another volume.
    func moveExclusive(from: URL, to: URL) -> MoveResult {
        if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 { return .success }
        let code = errno
        if code == EEXIST { return .exists }
        if code == EXDEV {
            if FileManager.default.fileExists(atPath: to.path) { return .exists }
            do {
                try FileManager.default.moveItem(at: from, to: to)   // copies then removes; refuses to overwrite
                return .success
            } catch let error as NSError where error.code == NSFileWriteFileExistsError {
                return .exists
            } catch {
                return .failure(DownloadError.from(error))
            }
        }
        return .failure(DownloadError.from(posix: code, detail: "rename failed"))
    }

    /// Marks the file as downloaded from the internet so Gatekeeper checks it on first open.
    public func applyQuarantine(to url: URL, info: QuarantineInfo) {
        var props: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "OleDownloadManager",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineDataURLKey as String: info.sourceURL,
        ]
        if let page = info.pageURL { props[kLSQuarantineOriginURLKey as String] = page }
        var values = URLResourceValues()
        values.quarantineProperties = props
        var mutable = url
        do { try mutable.setResourceValues(values) } catch {
            AppLog.filesystem.error("could not set quarantine: \(error.localizedDescription, privacy: .public)")
        }
    }
}

public enum IntegrityVerifier {
    /// Streams the file through SHA-256 in 1 MiB chunks (never loads it into memory).
    public static func sha256(of url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Normalizes a user-supplied checksum ("SHA256: ABCD..." → "abcd...") or returns nil if it isn't hex SHA-256.
    public static func normalizeSHA256(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["sha256:", "sha-256:", "sha256="] where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        guard s.count == 64, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        return s
    }

    public static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}
