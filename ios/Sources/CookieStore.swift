import Foundation
import Security

/// 网盘 Cookie 存储。
/// 首选 Keychain；免费签名 / 爱思助手签名有时没有 keychain-access-groups 权限（写入报 -34018），
/// 这时自动退回 UserDefaults，保证「登录了就能用」。
enum CookieStore {

    private static let service = "com.yunx.ios.cookies"
    private static let fallbackPrefix = "yunx.cookie."

    private(set) static var lastError: String = ""

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

        // 兜底存储先写，保证一定能读到
        UserDefaults.standard.set(trimmed, forKey: fallbackPrefix + platform.rawValue)

        var item = query(platform)
        SecItemDelete(item as CFDictionary)
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess {
            lastError = ""
        } else {
            lastError = "Keychain 写入失败(\(status))，已退回本地存储"
        }
    }

    static func load(_ platform: Platform) -> String? {
        if let data = keychainData(platform),
           let text = String(data: data, encoding: .utf8),
           !text.isEmpty {
            return text
        }
        if let text = UserDefaults.standard.string(forKey: fallbackPrefix + platform.rawValue), !text.isEmpty {
            return text
        }
        return nil
    }

    static func clear(_ platform: Platform) {
        SecItemDelete(query(platform) as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackPrefix + platform.rawValue)
    }

    private static func keychainData(_ platform: Platform) -> Data? {
        var item = query(platform)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// 各平台的登录态关键字段，用来判断 Cookie 是否真的可用
    static func missingKey(_ cookie: String, for platform: Platform) -> String? {
        switch platform {
        case .quark, .uc:
            if !cookie.contains("__pus=") { return "__pus" }
            if !cookie.contains("__puus=") { return "__puus" }
        case .baidu:
            if !cookie.contains("BDUSS=") { return "BDUSS" }
        }
        return nil
    }
}
