import Foundation
import Security

/// Stores the device token in the keychain. On iOS the app and its Share extension share it
/// through a keychain access group; set `accessGroup` before first use.
public enum Keychain {
    static let service = "com.3dvault.token"
    nonisolated(unsafe) public static var accessGroup: String?

    /// Adds the access group when one is set. Unsigned simulator builds lack the entitlement,
    /// so callers retry without it.
    private static func query(_ q: [String: Any], group: Bool) -> CFDictionary {
        var q = q
        if group, let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q as CFDictionary
    }

    public static func save(_ token: String, account: String) {
        delete(account: account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if SecItemAdd(query(q, group: true), nil) == errSecMissingEntitlement {
            SecItemAdd(query(q, group: false), nil)
        }
    }

    public static func load(account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        var status = SecItemCopyMatching(query(q, group: true), &out)
        if status == errSecMissingEntitlement { status = SecItemCopyMatching(query(q, group: false), &out) }
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if SecItemDelete(query(q, group: true)) == errSecMissingEntitlement {
            SecItemDelete(query(q, group: false))
        }
    }
}
