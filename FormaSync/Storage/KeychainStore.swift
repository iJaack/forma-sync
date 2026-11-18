import Foundation
import Security

enum KeychainError: LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let code):
            return "Errore del Portachiavi (\(code))."
        }
    }
}

/// Minimal Keychain wrapper. Items are readable after the first unlock (needed for background sync)
/// and never leave this device (no iCloud Keychain sync, not included in backups to other devices).
enum KeychainStore {
    // Keep this service name stable so existing installs retain their saved configuration.
    // The app's default Keychain access group already follows its signing team and bundle ID.
    private static let service: String = {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "FormaKeychainService") as? String,
           !configured.isEmpty {
            return configured
        }
        return (Bundle.main.bundleIdentifier ?? "formasync") + ".ingest"
    }()

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func set(_ value: String, for account: String) throws {
        let query = baseQuery(account)
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func get(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
