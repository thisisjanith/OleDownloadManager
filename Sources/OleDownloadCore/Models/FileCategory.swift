import Foundation

/// A user-configurable file category used for sidebar filtering and optional folder organization.
public struct FileCategory: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Sub-folder name used when "organize by category" is enabled.
    public var folderName: String
    /// Lower-cased extensions without dots.
    public var extensions: [String]
    public var symbolName: String

    public init(id: String, name: String, folderName: String, extensions: [String], symbolName: String) {
        self.id = id
        self.name = name
        self.folderName = folderName
        self.extensions = extensions
        self.symbolName = symbolName
    }

    public static let otherID = "other"

    public static let defaults: [FileCategory] = [
        FileCategory(id: "documents", name: "Documents", folderName: "Documents",
                     extensions: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "md",
                                  "pages", "numbers", "key", "odt", "ods", "epub", "csv"],
                     symbolName: "doc.text"),
        FileCategory(id: "applications", name: "Applications and Installers", folderName: "Applications",
                     extensions: ["dmg", "pkg", "mpkg", "app", "exe", "msi", "deb", "rpm", "appimage", "apk", "ipa"],
                     symbolName: "app.badge"),
        FileCategory(id: "archives", name: "Archives", folderName: "Archives",
                     extensions: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "iso", "sit", "lz", "lzma"],
                     symbolName: "archivebox"),
        FileCategory(id: "video", name: "Video", folderName: "Video",
                     extensions: ["mp4", "m4v", "mov", "mkv", "avi", "webm", "wmv", "flv", "mpg", "mpeg", "ts"],
                     symbolName: "film"),
        FileCategory(id: "audio", name: "Audio", folderName: "Audio",
                     extensions: ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "aiff", "wma", "alac"],
                     symbolName: "music.note"),
        FileCategory(id: "images", name: "Images", folderName: "Images",
                     extensions: ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "tif", "bmp", "svg", "raw", "psd"],
                     symbolName: "photo"),
        FileCategory(id: otherID, name: "Other", folderName: "Other", extensions: [], symbolName: "questionmark.folder"),
    ]

    /// Returns the id of the first category whose extension list contains the file's extension.
    public static func classify(fileName: String, categories: [FileCategory]) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        // Handle double extensions such as .tar.gz by also checking the last extension only.
        guard !ext.isEmpty else { return otherID }
        for category in categories where category.id != otherID {
            if category.extensions.contains(ext) { return category.id }
        }
        return otherID
    }
}
