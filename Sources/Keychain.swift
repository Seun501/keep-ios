import Foundation
import Security

/// 口令存钥匙串，不存 UserDefaults（后者明文进备份）。
enum Keychain {
    private static let service = "cn.seunk.keep"
    private static let account = "gateway-token"

    static var token: String? {
        get {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty
            else { return nil }
            return s
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: service,
                                       kSecAttrAccount as String: account]
            SecItemDelete(base as CFDictionary)
            guard let v = newValue, let data = v.data(using: .utf8) else { return }
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let st = SecItemAdd(add as CFDictionary, nil)
            if st != errSecSuccess { PushRegistrar.diag("keychain add failed: \(st)") }
        }
    }
}
