import Foundation
import Security

/// 网盘 Cookie 存 Keychain，卸载 App 才清除；页面不回显完整值。
enum CookieStore {

    private static let service = "com.yunx.ios.cookies"

    private static func query(_ platform: Platform) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: platform.rawValue
        ]
    }

    static func save(_ value: String, for platform: Platform) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clear(platform); return }
        var item = query(platform)
        SecItemDelete(item as CFDictionary)
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load(_ platform: Platform) -> String? {
        var item = query(platform)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    static func clear(_ platform: Platform) {
        SecItemDelete(query(platform) as CFDictionary)
    }
}
