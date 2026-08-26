// goty — see CLAUDE.md for the working principles.
import Foundation
import Security

// MARK: - Keychain (API keys never touch UserDefaults)

/// Minimal generic-password store. The AI API key is the only user of
/// v1; a nil `value` deletes the item so callers can clear state with
/// the same call they use to set it.
enum Keychain {
    /// Tests redirect every item into an isolated service so the suite
    /// never reads or writes the user's real credentials — a real-item
    /// write from a rebuilt test binary pops a keychain ACL dialog on
    /// every run (and would clobber the stored key).
    static var serviceOverrideForTests: String?
    private static var service: String { serviceOverrideForTests ?? "goty.ai" }

    static func setSecret(_ value: String?, for key: String) {
        // Keep the in-process cache authoritative: a write must never
        // leave a stale cached secret behind.
        cache[key] = value
        if let value {
            let data = Data(value.utf8)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ]
            let attrs: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            if status == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                SecItemAdd(add as CFDictionary, nil)
            }
        } else {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    /// Existence check WITHOUT decrypting the secret: a data-less
    /// query never trips the keychain ACL prompt. UI status lines
    /// must use THIS, not `secret(for:)` — every real read of an
    /// item created by an earlier build pops the "wants to use your
    /// confidential information" dialog (dev binaries re-sign each
    /// build, so the ACL never sticks).
    static func hasSecret(for key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Per-process cache: the keychain prompts per READ when the ACL
    /// doesn't cover the running binary (every rebuilt dev build), so
    /// repeated reads — per settings rebuild, per @ai task — must hit
    /// memory, not the Security server. The secret is already resident
    /// in the API client after the first read; this adds no exposure.
    private static var cache: [String: String] = [:]

    static func secret(for key: String) -> String? {
        if let hit = cache[key] { return hit }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        let value = String(data: data, encoding: .utf8)
        cache[key] = value
        return value
    }
}
