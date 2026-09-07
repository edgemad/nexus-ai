import Foundation
import Security

/// Storage backend for credentials. The production backend is the macOS
/// Keychain; tests inject an in-memory one.
protocol SecretBackend {
    func save(_ value: String, for key: String) throws
    func read(_ key: String) throws -> String?
    func delete(_ key: String) throws
}

enum SecretKeychainItem: Error, Equatable {
    case missing
    case keychain(OSStatus)
}

/// Keychain-backed credential storage. Never store API keys in UserDefaults —
/// that leaves them readable in plaintext backups and process dumps.
struct KeychainBackend: SecretBackend {
    static let serviceName = "com.nexie.app.secrets"

    func save(_ value: String, for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(query as CFDictionary) // update-in-place
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretKeychainItem.keychain(status) }
    }

    func read(_ key: String) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SecretKeychainItem.keychain(status)
        }
        return String(data: data, encoding: .utf8)
    }

    func delete(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretKeychainItem.keychain(status)
        }
    }
}

/// Convenience façade with a one-time migration path for credentials that were
/// previously stored in UserDefaults.
enum SecretStore {
    static var backend: SecretBackend = KeychainBackend()

    static func save(_ value: String, for key: String) throws {
        try backend.save(value, for: key)
    }

    static func read(_ key: String) throws -> String? {
        try backend.read(key)
    }

    static func delete(_ key: String) throws {
        try backend.delete(key)
    }

    /// Migrates a legacy UserDefaults-stored secret into the Keychain (same
    /// account key) and removes the plaintext copy. No-op if already migrated.
    /// Returns the value if present anywhere, else nil.
    @discardableResult
    static func migrateLegacyIfNeeded(_ key: String,
                                      defaults: UserDefaults = .standard) -> String? {
        if let stored = try? read(key), !stored.isEmpty { return stored }
        guard let legacy = defaults.string(forKey: key), !legacy.isEmpty else { return nil }
        try? save(legacy, for: key)
        defaults.removeObject(forKey: key)
        return legacy
    }
}