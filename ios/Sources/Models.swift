import Foundation

/// 支持的网盘平台。新增平台时在这里加 case，并在对应 Client / Drive 里补接口差异。
enum Platform: String, CaseIterable, Identifiable, Hashable {
    case quark = "QUARK"
    case uc = "UC"
    case baidu = "BAIDU"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quark: return "夸克网盘"
        case .uc: return "UC 网盘"
        case .baidu: return "百度网盘"
        }
    }

    var apiBase: String {
        switch self {
        case .quark: return "https://drive-pc.quark.cn"
        case .uc: return "https://pc-api.uc.cn"
        case .baidu: return "https://pan.baidu.com"
        }
    }

    var referer: String {
        switch self {
        case .quark: return "https://pan.quark.cn/"
        case .uc: return "https://drive.uc.cn/"
        case .baidu: return "https://pan.baidu.com/"
        }
    }

    var loginURL: URL {
        URL(string: loginURLString)!
    }

    /// 登录页地址：夸克/百度首页往下滑有登录区；UC 直接用微信扫码登录页
    var loginURLString: String {
        switch self {
        case .quark: return "https://pan.quark.cn/"
        case .uc: return "https://drive.uc.cn/account/wxlogin"
        case .baidu: return "https://pan.baidu.com/"
        }
    }

    /// 登录页提示
    var loginHint: String {
        switch self {
        case .quark: return "页面往下滑，找到「登录账号」区域；也可以点下面「跳到登录区」"
        case .uc: return "用微信扫码登录；扫不了就回到 drive.uc.cn 首页找手机号登录"
        case .baidu: return "账号密码或扫码都行，登录后点右上角「完成」"
        }
    }

    /// 需要滚动定位的锚点（夸克页面里的登录区 id）
    var loginAnchor: String? {
        self == .quark ? "登录账号" : nil
    }

    var cookieHost: String {
        switch self {
        case .quark: return "quark.cn"
        case .uc: return "uc.cn"
        case .baidu: return "baidu.com"
        }
    }

    /// 服务端会校验客户端 UA，必须和 PC 客户端一致
    var userAgent: String {
        switch self {
        case .quark:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
                + "quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.12-a038f7b798 "
                + "Safari/537.36 Channel/pckk_other_ch"
        case .uc:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
                + "uc-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.12-a038f7b798 "
                + "Safari/537.36 Channel/pckk_other_ch"
        case .baidu:
            return BaiduClient.webUA
        }
    }

    /// 登录网页用的浏览器 UA（客户端 UA 会被当成 App 内浏览器，页面会跳下载页）
    var webBrowserUA: String {
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
            + "Chrome/124.0.0.0 Safari/537.36"
    }
}

struct ParsedShare {
    let platform: Platform
    let shareID: String
    let pwd: String?
}

struct CloudFile: Identifiable {
    let fid: String
    let shareToken: String
    let name: String
    let size: Int64
    let isDir: Bool

    var id: String { fid }

    var sizeText: String {
        isDir ? "—" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var iconName: String {
        if isDir { return "folder" }
        let lower = name.lowercased()
        if lower.hasSuffix(".mp4") || lower.hasSuffix(".mkv") || lower.hasSuffix(".mov") { return "play.rectangle" }
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".png") || lower.hasSuffix(".jpeg") { return "photo" }
        if lower.hasSuffix(".mp3") || lower.hasSuffix(".flac") || lower.hasSuffix(".m4a") { return "music.note" }
        return "doc"
    }
}

struct DirectLink {
    let url: URL
    let headers: [String: String]
}

enum AppError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}
