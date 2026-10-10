import Foundation
import Security

/// Generic-password items in the login keychain.
enum Keychain {
    static func read(service: String, account: String) -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// An empty value deletes the item.
    static func write(_ value: String, service: String, account: String) throws {
        guard (read(service: service, account: account) ?? "") != value else { return }
        let query = baseQuery(service: service, account: account)
        var status: OSStatus
        if value.isEmpty {
            status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { status = errSecSuccess }
        } else {
            let data = Data(value.utf8)
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                status = SecItemAdd(add as CFDictionary, nil)
            }
        }
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain: \(message)"])
        }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
