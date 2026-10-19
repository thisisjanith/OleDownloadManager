import Foundation
import UniformTypeIdentifiers

public enum FileNameSanitizer {
    public static let fallbackName = "download"
    static let maxUTF8Bytes = 255

    /// Turns an untrusted name (from a URL, a header or a browser) into a single safe path component.
    /// Removes path separators, control characters and leading dots; never returns "", "." or "..".
    public static func sanitize(_ raw: String, fallback: String = fallbackName) -> String {
        var name = raw.precomposedStringWithCanonicalMapping
        // Only keep the last path component of anything that looks like a path.
        if let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last { name = String(last) }
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar {
            case "/", "\\", ":": scalars.append("_")
            case "\0": continue
            default:
                if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.illegalCharacters.contains(scalar) {
                    continue
                }
                // Drop bidi overrides that can disguise an extension ("exe.pdf" shown as "fdp.exe").
                if (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) { continue }
                scalars.append(scalar)
            }
        }
        name = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        while name.hasSuffix(".") || name.hasSuffix(" ") { name.removeLast() }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == "." || name == ".." { name = fallback }
        return truncate(name)
    }

    /// Keeps the name within the file system's 255-byte limit while preserving the extension.
    static func truncate(_ name: String) -> String {
        guard name.utf8.count > maxUTF8Bytes else { return name }
        let ext = (name as NSString).pathExtension
        let extPart = ext.isEmpty || ext.utf8.count > 32 ? "" : "." + ext
        var base = extPart.isEmpty ? name : String(name.dropLast(extPart.count))
        while base.utf8.count + extPart.utf8.count > maxUTF8Bytes, !base.isEmpty { base.removeLast() }
        return base + extPart
    }

    /// Suggests a file name: Content-Disposition, then the URL path, then a generated fallback.
    /// Adds an extension from the MIME type when the name has none.
    public static func suggestedName(contentDisposition: String?, url: URL?, mimeType: String?) -> String {
        var candidate: String?
        if let fromHeader = ContentDisposition.fileName(from: contentDisposition) {
            candidate = fromHeader
        } else if let url {
            let last = url.lastPathComponent
            if !last.isEmpty, last != "/" {
                candidate = last.removingPercentEncoding ?? last
            }
        }
        var name = sanitize(candidate ?? fallbackName)
        if (name as NSString).pathExtension.isEmpty, let mimeType,
           let ext = UTType(mimeType: mimeType.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? mimeType)?.preferredFilenameExtension,
           mimeType.lowercased().hasPrefix("text/html") == false || candidate == nil {
            name += "." + ext
        }
        return name
    }

    /// Joins `name` to `directory` and verifies the result stays inside `directory`.
    public static func safeDestination(directory: URL, name: String) -> URL? {
        let safe = sanitize(name)
        let dir = directory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = dir.appendingPathComponent(safe, isDirectory: false).standardizedFileURL
        guard candidate.deletingLastPathComponent().path == dir.path else { return nil }
        return candidate
    }

    /// "name.ext" → "name (n).ext"; handles ".tar.gz" style double extensions.
    public static func numbered(_ name: String, _ n: Int) -> String {
        let lower = name.lowercased()
        for compound in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst"] where lower.hasSuffix(compound) && name.count > compound.count {
            let base = String(name.dropLast(compound.count))
            return "\(base) (\(n))\(name.suffix(compound.count))"
        }
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        return ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
    }
}
