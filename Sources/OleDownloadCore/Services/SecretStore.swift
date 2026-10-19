import Foundation
import Security

/// Credentials and sensitive headers for one download. Never written to SQLite.
public struct DownloadSecrets: Codable, Sendable, Equatable {
    public var user: String?
    public var password: String?
    /// Authorization, Cookie and similar headers the user typed in.
    public var sensitiveHeaders: [String: String]

    public init(user: String? = nil, password: String? = nil, sensitiveHeaders: [String: String] = [:]) {
        self.user = user
        self.password = password
        self.sensitiveHeaders = sensitiveHeaders
    }

    public var isEmpty: Bool { (user ?? "").isEmpty && (password ?? "").isEmpty && sensitiveHeaders.isEmpty }

    public var credentials: BasicCredentials? {
        guard let user, !user.isEmpty else { return nil }
        return BasicCredentials(user: user, password: password ?? "")
    }
}

public protocol SecretStore: Sendable {
    func save(_ secrets: DownloadSecrets, for id: UUID) throws
    func load(for id: UUID) -> DownloadSecrets?
    func delete(for id: UUID)
}

/// Stores secrets as generic-password items in the user's login keychain, only after explicit consent.
public struct KeychainSecretStore: SecretStore {
    public static let service = "com.oledownloadmanager.app.download-credentials"

    public init() {}

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: id.uuidString]
    }

    public func save(_ secrets: DownloadSecrets, for id: UUID) throws {
        let data = try JSONEncoder().encode(secrets)
        SecItemDelete(query(id) as CFDictionary)
        var item = query(id)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "OleDownloadManager download credentials"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DownloadError(.unknown, "The credentials could not be saved to the Keychain (\(status)).")
        }
    }

    public func load(for id: UUID) -> DownloadSecrets? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(DownloadSecrets.self, from: data)
    }

    public func delete(for id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: DownloadSecrets] = [:]
    public init() {}
    public func save(_ secrets: DownloadSecrets, for id: UUID) throws { lock.withLock { storage[id] = secrets } }
    public func load(for id: UUID) -> DownloadSecrets? { lock.withLock { storage[id] } }
    public func delete(for id: UUID) { _ = lock.withLock { storage.removeValue(forKey: id) } }
}
