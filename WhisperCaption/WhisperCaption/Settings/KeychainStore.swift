import Foundation
import Security

/// Tiny wrapper around the `Security` framework for storing one secret
/// per account name in the user's login keychain. We use it for cloud
/// engine API keys (Deepgram, ElevenLabs) — keeping them out of
/// UserDefaults (which is effectively plaintext on disk).
enum KeychainStore {

    private static let service = "com.albond.WhisperCaption"

    /// Returns the stored secret for `account`, or empty string if absent.
    /// Empty string is the natural "not set" value because the Settings UI
    /// binds directly to a String (not an Optional) for SecureField input.
    static func read(account: String) -> String {
        var query: [String: Any] = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return "" }
        return value
    }

    /// Writes `value` for `account`. Empty string deletes the entry.
    static func write(_ value: String, account: String) {
        if value.isEmpty {
            delete(account: account)
            return
        }
        guard let data = value.data(using: .utf8) else { return }

        // Try to update first; if the entry doesn't exist, add it.
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func delete(account: String) {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        return [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
