import Foundation

struct BaiduShareState {
    let surl: String
    let shareID: String
    let uk: String
    let randsk: String
    let sign: String
    let timestamp: String
}

/// 百度网盘分享客户端。
///
/// 流程（和 AList / BaiduPCS 的网页端实现一致）：
/// 1. GET  分享页 HTML → 抓 shareid / share_uk / sign / timestamp
/// 2. POST /share/verify   → randsk（带提取码时）
/// 3. GET  /share/list     → 文件列表（fs_id / server_filename / isdir / path）
/// 4. POST /api/sharedownload → dlink（要带 sign/timestamp/BDCLND）
/// 5. 下载 dlink：UA 用 `pan.baidu.com`，带 Cookie + Referer
struct BaiduClient {

    let cookie: String

    static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    static let downloadUA = "pan.baidu.com"

    // MARK: - URL

    private func url(_ base: String, _ items: [String: String]) -> URL {
        var comp = URLComponents(string: base)!
        comp.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        return comp.url!
    }

    private func cookieHeader(randsk: String?) -> String {
        var value = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        if let randsk, !randsk.isEmpty {
            if !value.isEmpty { value += "; " }
            value += "BDCLND=\(randsk)"
        }
        return value
    }

    // MARK: - 1. 分享页

    struct PageFields {
        var shareID: String?
        var uk: String?
        var sign: String?
        var timestamp: String?
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = re.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    static func parsePage(_ html: String) -> PageFields {
        var fields = PageFields()
        fields.shareID = capture("\"shareid\":(\\d+)", in: html)
        fields.uk = capture("\"share_uk\":\"?(\\d+)\"?", in: html)
            ?? capture("\"uk\":\"?(\\d+)\"?", in: html)
        fields.sign = capture("\"sign\":\"([0-9A-Za-z]+)\"", in: html)
        fields.timestamp = capture("\"timestamp\":(\\d+)", in: html)
        return fields
    }

    func loadSharePage(surl: String, pwd: String?, randsk: String?) async throws -> String {
        var items: [String: String] = [:]
        if let pwd, !pwd.isEmpty { items["pwd"] = pwd }
        var request = URLRequest(url: url("https://pan.baidu.com/s/1\(surl)", items))
        request.setValue(Self.webUA, forHTTPHeaderField: "User-Agent")
        let cookies = cookieHeader(randsk: randsk)
        if !cookies.isEmpty { request.setValue(cookies, forHTTPHeaderField: "Cookie") }

        let result: (Data, URLResponse)
        do {
            result = try await Net.session.data(for: request)
        } catch {
            throw AppError.message("打开百度分享页失败：\(error.localizedDescription)")
        }
        guard let http = result.1 as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            throw AppError.message("百度分享页打不开（可能需要登录或链接失效）")
        }
        return String(data: result.0, encoding: .utf8) ?? ""
    }

    // MARK: - 2. 提取码校验

    func verify(surl: String, pwd: String) async throws -> String {
        let target = url("https://pan.baidu.com/share/verify", [
            "surl": surl,
            "t": "\(Int(Date().timeIntervalSince1970))",
            "channel": "chunlei",
            "web": "1",
            "app_id": "250528",
            "clienttype": "0"
        ])
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.webUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://pan.baidu.com/s/1\(surl)", forHTTPHeaderField: "Referer")
        let cookies = cookieHeader(randsk: nil)
        if !cookies.isEmpty { request.setValue(cookies, forHTTPHeaderField: "Cookie") }
        let encodedPwd = pwd.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? pwd
        request.httpBody = "pwd=\(encodedPwd)&vcode=&vcode_str=".data(using: .utf8)

        let json = try await Net.json(request)
        try Self.checkErrno(json)
        guard let randsk = json["randsk"] as? String, !randsk.isEmpty else {
            throw AppError.message("提取码校验失败（没拿到 randsk）")
        }
        return randsk.removingPercentEncoding ?? randsk
    }

    // MARK: - 3. 列目录

    func list(state: BaiduShareState, dir: String) async throws -> [CloudFile] {
        var result: [CloudFile] = []
        var page = 1
        while page <= 20 {
            let target = url("https://pan.baidu.com/share/list", [
                "uk": state.uk,
                "shareid": state.shareID,
                "order": "other",
                "desc": "1",
                "showempty": "0",
                "web": "1",
                "page": "\(page)",
                "num": "100",
                "dir": dir,
                "t": "\(Int(Date().timeIntervalSince1970))",
                "channel": "chunlei",
                "app_id": "250528",
                "bdstoken": "",
                "clienttype": "0"
            ])
            var request = URLRequest(url: target)
            request.setValue(Self.webUA, forHTTPHeaderField: "User-Agent")
            request.setValue("https://pan.baidu.com/s/1\(state.surl)", forHTTPHeaderField: "Referer")
            let cookies = cookieHeader(randsk: state.randsk)
            if !cookies.isEmpty { request.setValue(cookies, forHTTPHeaderField: "Cookie") }

            let json = try await Net.json(request)
            try Self.checkErrno(json)
            let items = json["list"] as? [[String: Any]] ?? []
            for item in items {
                let isDir = ((item["isdir"] as? NSNumber)?.intValue ?? 0) == 1
                let path = item["path"] as? String ?? ""
                let fsID = (item["fs_id"] as? NSNumber)?.stringValue ?? ""
                guard !(isDir && path.isEmpty), !(!isDir && fsID.isEmpty) else { continue }
                result.append(CloudFile(
                    fid: isDir ? path : fsID,
                    shareToken: "",
                    name: item["server_filename"] as? String ?? "未命名",
                    size: (item["size"] as? NSNumber)?.int64Value ?? 0,
                    isDir: isDir
                ))
            }
            if items.count < 100 { break }
            page += 1
        }
        return result
    }

    // MARK: - 4. 取 dlink

    func direct(state: BaiduShareState, fsID: String) async throws -> DirectLink {
        guard !state.sign.isEmpty, !state.timestamp.isEmpty else {
            throw AppError.message("百度没有返回 sign/时间戳，重新解析一次（或链接需要提取码）")
        }
        let target = url("https://pan.baidu.com/api/sharedownload", [
            "sign": state.sign,
            "timestamp": state.timestamp,
            "channel": "chunlei",
            "web": "1",
            "app_id": "250528",
            "clienttype": "0"
        ])
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.webUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://pan.baidu.com/s/1\(state.surl)", forHTTPHeaderField: "Referer")
        let cookies = cookieHeader(randsk: state.randsk)
        if !cookies.isEmpty { request.setValue(cookies, forHTTPHeaderField: "Cookie") }
        request.httpBody = "encrypt=0&product=share&type=dlink&fid_list=[\(fsID)]".data(using: .utf8)

        let json = try await Net.json(request)
        try Self.checkErrno(json)
        guard let list = json["list"] as? [[String: Any]],
              let dlink = list.first?["dlink"] as? String,
              let dlURL = URL(string: dlink) else {
            throw AppError.message("百度没有返回下载地址（可能被限速或需要登录）")
        }
        return DirectLink(url: dlURL, headers: [
            "User-Agent": Self.downloadUA,
            "Referer": "https://pan.baidu.com/",
            "Cookie": cookieHeader(randsk: state.randsk)
        ])
    }

    // MARK: - 组合流程

    func resolve(surl: String, pwd: String?) async throws -> (state: BaiduShareState, files: [CloudFile]) {
        var randsk = ""
        var html = try await loadSharePage(surl: surl, pwd: pwd, randsk: nil)
        var fields = Self.parsePage(html)

        if let pwd, !pwd.isEmpty {
            randsk = try await verify(surl: surl, pwd: pwd)
            // 带提取码的分享页，校验后才会吐 sign
            if fields.sign == nil || fields.shareID == nil {
                html = try await loadSharePage(surl: surl, pwd: pwd, randsk: randsk)
                fields = Self.parsePage(html)
            }
        }

        guard let shareID = fields.shareID, let uk = fields.uk else {
            throw AppError.message("百度分享页解析失败：需要提取码，或页面结构已更新")
        }
        let state = BaiduShareState(
            surl: surl,
            shareID: shareID,
            uk: uk,
            randsk: randsk,
            sign: fields.sign ?? "",
            timestamp: fields.timestamp ?? ""
        )
        let files = try await list(state: state, dir: "/")
        return (state, files)
    }

    // MARK: - 错误码

    static func checkErrno(_ json: [String: Any]) throws {
        let errno = (json["errno"] as? NSNumber)?.intValue ?? 0
        guard errno != 0 else { return }
        let message: String
        switch errno {
        case -6: message = "百度未登录或 Cookie 失效，去「账号」重新登录"
        case -9: message = "提取码错误"
        case -62: message = "触发百度风控，要求验证码（先在浏览器里打开一次该分享）"
        case 2: message = "参数错误，百度接口可能已变更"
        case 112: message = "分享链接已失效"
        case 118: message = "百度限速中，稍后再试"
        case 31066: message = "文件不存在（可能已被删除或和谐）"
        default: message = "百度返回 errno=\(errno)"
        }
        throw AppError.message(message)
    }
}
