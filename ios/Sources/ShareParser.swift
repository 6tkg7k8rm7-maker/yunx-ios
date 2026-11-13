import Foundation

/// 分享链接识别：移植自 YunX-Desktop 的 ShareLinkParser.kt（只保留夸克 / UC）
enum ShareParser {

    private static func regex(_ pattern: String) -> NSRegularExpression {
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
            ?? NSRegularExpression()
    }

    private static let urlRE = regex("https?://[^\\s]+")
    private static let pwdURLRE = regex("[?&]pwd=([A-Za-z0-9]+)")
    private static let pwdTextRE = regex("(?:提取码|访问码|密码)[：:]\\s*([A-Za-z0-9]{4,8})")

    private static func firstGroup(_ re: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = re.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func firstURL(in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = urlRE.firstMatch(in: text, options: [], range: range),
              let r = Range(match.range, in: text) else { return nil }
        var url = String(text[r])
        let junk = CharacterSet(charactersIn: "。，,；;)]}\"'")
        while let last = url.unicodeScalars.last, junk.contains(last) {
            url.removeLast()
        }
        return url
    }

    private static let patterns: [(Platform, NSRegularExpression)] = [
        (.quark, regex("pan\\.quark\\.cn/s/([A-Za-z0-9]+)")),
        (.uc, regex("drive\\.uc\\.cn/s/([A-Za-z0-9]+)")),
    ]

    static func parse(_ text: String) -> ParsedShare? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = firstURL(in: trimmed) else { return nil }

        for (platform, re) in patterns {
            if let shareID = firstGroup(re, in: url) {
                let pwd = firstGroup(pwdURLRE, in: url) ?? firstGroup(pwdTextRE, in: trimmed)
                return ParsedShare(platform: platform, shareID: shareID, pwd: pwd)
            }
        }
        return nil
    }
}
