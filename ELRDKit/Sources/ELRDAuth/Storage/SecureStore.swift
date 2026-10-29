import Foundation
import Security

/// Kleiner geschützter Speicher für Sitzungsdaten und später Backend-Zugangsdaten.
@MainActor
public protocol SecureStore: AnyObject {
    func data(for key: String) throws -> Data?
    func set(_ data: Data?, for key: String) throws
}

public extension SecureStore {
    func string(for key: String) throws -> String? {
        try data(for: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    func set(_ string: String?, for key: String) throws {
        try set(string.map { Data($0.utf8) }, for: key)
    }
}

public enum SecureStoreError: Error, Equatable, Sendable {
    case keychain(OSStatus)
}

/// Keychain des Geräts. Einträge sind nur auf diesem Gerät und erst nach der
/// ersten Entsperrung lesbar; sie werden nicht in Backups übertragen.
@MainActor
public final class KeychainStore: SecureStore {
    private let service: String

    public init(service: String = "ELRD") {
        self.service = service
    }

    public func data(for key: String) throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw SecureStoreError.keychain(status)
        }
    }

    public func set(_ data: Data?, for key: String) throws {
        let query = baseQuery(key)
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SecureStoreError.keychain(status) }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SecureStoreError.keychain(status) }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

/// Speicher im Arbeitsspeicher für Tests und Vorschauen.
@MainActor
public final class InMemorySecureStore: SecureStore {
    private var values: [String: Data] = [:]
    public init() {}
    public func data(for key: String) throws -> Data? { values[key] }
    public func set(_ data: Data?, for key: String) throws { values[key] = data }
}
