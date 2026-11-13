import Foundation

/// 百度分享状态：share_id / uk 从列表接口返回，sekey 即 verify 的 randsk
struct BaiduShareState {
    let surl: String
    let shareID: String
    let uk: String
    /// 原始形式（可能含 %3D）：BDCLND Cookie 必须用它
    let sekey: String
    /// 查询参数用：解码后交给严格编码，避免二次编码
    var sekeyQuery: String { sekey.removingPercentEncoding ?? sekey }
}

/// 百度网盘分享客户端（对齐 YunX-Desktop 的 BaiduApi.kt 链路）：
/// bdstoken → share/verify → xpan/share(method=list) → share/transfer → locatedownload
/// 转存失败时回退：share/tplconfig 取 sign → api/sharedownload
struct BaiduClient {

    let cookie: String

    static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    static let netdiskUA = "netdisk;12.24.6;piano;android-android;16;JSbridge4.4.0;jointBridge;1.1.0"
    static let appID = "250528"
    static let transferDir = "/云析下载"

    private static var cachedBdstoken: String?

    // MARK: - 基础

    private func url(_ base: String, _ items: [(String, String)]) -> URL {
        Net.url(base, items)
    }

    private func withSekey(_ cookie: String, _ sekey: String) -> String {
        var value = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sekey.isEmpty, !value.contains("BDCLND=") else { return value }
        if !value.isEmpty { value += "; " }
        value += "BDCLND=\(sekey)"
        return value
    }

    static func clearCache() {
        cachedBdstoken = nil
    }

    // MARK: - bdstoken

    func bdstoken() async throws -> String {
        if let cached = Self.cachedBdstoken, !cached.isEmpty { return cached }
        let target = url("https://pan.baidu.com/api/gettemplatevariable", [
            ("clienttype", "0"), ("app_id", Self.appID), ("web", "1"),
            ("fields", "[\"bdstoken\"]")
        ])
        var request = URLRequest(url: target)
        request.setValue(Self.webUA, forHTTPHeaderField: "User-Agent")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let json = try await Net.json(request, platform: "BAIDU", step: "取 bdstoken")
        try Self.checkErrno(json)
        guard let result = json["result"] as? [String: Any],
              let token = result["bdstoken"] as? String, !token.isEmpty else {
            throw AppError.message("取 bdstoken：百度没返回（Cookie 可能不是登录态）")
        }
        Self.cachedBdstoken = token
        return token
    }

    // MARK: - 1. 提取码

    func verify(surl: String, pwd: String) async throws -> String {
        let target = url("https://pan.baidu.com/share/verify", [("surl", surl)])
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue(Self.webUA, forHTTPHeaderField: "User-Agent")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://pan.baidu.com/s/\(surl)", forHTTPHeaderField: "Referer")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encodedPwd = pwd.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? pwd
        request.httpBody = "pwd=\(encodedPwd)&vcode_str=&vcode=".data(using: .utf8)

        let json = try await Net.json(request, platform: "BAIDU", step: "验证提取码")
        try Self.checkErrno(json)
        guard let randsk = json["randsk"] as? String, !randsk.isEmpty else {
            throw AppError.message("验证提取码：没有返回 randsk")
        }
        return randsk
    }

    // MARK: - 2. 列目录

    struct ListResult {
        let files: [CloudFile]
        let shareID: String
        let uk: String
        let title: String
    }

    func list(surl: String, sekey: String, dir: String) async throws -> ListResult {
        let isRoot = dir.isEmpty || dir == "/"
        var items: [(String, String)] = [
            ("method", "list"),
            ("shorturl", surl),
            ("page", "1"),
            ("num", "100"),
            ("root", isRoot ? "1" : "0"),
            ("dir", dir.isEmpty ? "/" : dir)
        ]
        if !sekey.isEmpty {
            items.append(("sekey", sekey.removingPercentEncoding ?? sekey))
        }

        var request = URLRequest(url: url("https://pan.baidu.com/rest/2.0/xpan/share", items))
        request.setValue(Self.webUA, forHTTPHeaderField: "User-Agent")
        request.setValue(withSekey(cookie, sekey), forHTTPHeaderField: "Cookie")
        request.setValue("https://pan.baidu.com/s/\(surl)", forHTTPHeaderField: "Referer")

        let json = try await Net.json(request, platform: "BAIDU", step: "列目录")
        let errno = (json["errno"] as? NSNumber)?.intValue ?? 0
        if errno != 0 {
            if sekey.isEmpty {
                throw AppError.message(errno == -6
                    ? "该分享需要提取码，或需要登录百度网盘（errno=-6）"
                    : "该分享需要提取码（errno=\(errno)）")
            }
            try Self.checkErrno(json)
        }

        let rawList = json["list"] as? [[String: Any]] ?? []
        var files: [CloudFile] = []
        for item in rawList {
            let isDir = (item["isdir"] as? NSNumber)?.intValue == 1
                || (item["isdir"] as? String) == "1"
            let path = item["path"] as? String ?? ""
            let fsID = (item["fs_id"] as? NSNumber)?.stringValue ?? (item["fs_id"] as? String) ?? ""
            guard isDir ? !path.isEmpty : !fsID.isEmpty else { continue }
            files.append(CloudFile(
                fid: isDir ? path : fsID,
                shareToken: "",
                name: item["server_filename"] as? String ?? "未命名",
                size: (item["size"] as? NSNumber)?.int64Value ?? 0,
                isDir: isDir
            ))
        }
        return ListResult(
            files: files,
            shareID: (json["share_id"] as? NSNumber)?.stringValue ?? (json["share_id"] as? String) ?? "",
            uk: (json["uk"] as? NSNumber)?.stringValue ?? (json["uk"] as? String) ?? "",
            title: json["title"] as? String ?? ""
        )
    }

    func listSub(state: BaiduShareState, dir: String) async throws -> [CloudFile] {
        try await list(surl: state.surl, sekey: state.sekey, dir: dir).files
    }

    // MARK: - 3. 转存

    private enum SekeyUse { case decoded, raw, none }

    /// 百度对 sekey 的编码在两处不一致：这里按三种组合依次重试，命中即返回
    func transfer(state: BaiduShareState, fsID: String, toDir: String) async throws -> String {
        var lastError: Error?
        do { return try await transferOnce(state: state, fsID: fsID, toDir: toDir, query: .decoded, cookie: .raw) }
        catch { lastError = error }
        do { return try await transferOnce(state: state, fsID: fsID, toDir: toDir, query: .raw, cookie: .raw) }
        catch { lastError = error }
        do { return try await transferOnce(state: state, fsID: fsID, toDir: toDir, query: .none, cookie: .decoded) }
        catch { lastError = error }
        throw lastError ?? AppError.message("转存失败")
    }

    private func transferOnce(state: BaiduShareState,
                              fsID: String,
                              toDir: String,
                              query: SekeyUse,
                              cookie cookieUse: SekeyUse) async throws -> String {
        let token = try await bdstoken()

        var base = "https://pan.baidu.com/share/transfer?"
            + "shareid=\(Net.encode(state.shareID))"
            + "&from=\(Net.encode(state.uk))"
            + "&channel=chunlei&ondup=newcopy&web=1"
            + "&app_id=\(Self.appID)&bdstoken=\(Net.encode(token))&clienttype=0"
        switch query {
        case .decoded: base += "&sekey=\(Net.encode(state.sekeyQuery))"
        case .raw: base += "&sekey=\(state.sekey)"
        case .none: break
        }

        var cookieValue = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        switch cookieUse {
        case .decoded: cookieValue = withSekey(cookieValue, state.sekeyQuery)
        case .raw: cookieValue = withSekey(cookieValue, state.sekey)
        case .none: break
        }

        var request = URLRequest(url: URL(string: base)!)
        request.httpMethod = "POST"
        request.setValue(Self.webUA, forHTTPHeaderField: "User-Agent")
        request.setValue(cookieValue, forHTTPHeaderField: "Cookie")
        request.setValue("https://pan.baidu.com", forHTTPHeaderField: "Origin")
        request.setValue("https://pan.baidu.com/s/", forHTTPHeaderField: "Referer")
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        let body = "fsidlist=%5B%22\(fsID)%22%5D&path=\(Net.encode(toDir))"
        request.httpBody = body.data(using: .utf8)

        let json = try await Net.json(request, platform: "BAIDU", step: "转存")
        try Self.checkErrno(json)
        guard let extra = json["extra"] as? [String: Any],
              let list = extra["list"] as? [[String: Any]],
              let first = list.first,
              let to = first["to"] as? String, !to.isEmpty else {
            throw AppError.message("转存：百度没返回新文件路径")
        }
        return to
    }

    /// 百度不接受转存到根目录（errno=2），必须先有一个真实目录
    func ensureTransferDir() async throws -> String {
        do {
            let token = try await bdstoken()
            let target = url("https://pan.baidu.com/api/create", [
                ("a", "commit"), ("channel", "chunlei"), ("web", "1"),
                ("app_id", Self.appID), ("clienttype", "0"), ("bdstoken", token)
            ])
            var request = URLRequest(url: target)
            request.httpMethod = "POST"
            request.setValue(Self.webUA, forHTTPHeaderField: "User-Agent")
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.setValue("https://pan.baidu.com/disk/main", forHTTPHeaderField: "Referer")
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            let body = "path=\(Net.encode(Self.transferDir))&isdir=1&size&block_list=%5B%5D&method=post&dataType=json"
            request.httpBody = body.data(using: .utf8)
            let json = try await Net.json(request, platform: "BAIDU", step: "建转存目录")
            let errno = (json["errno"] as? NSNumber)?.intValue ?? 0
            if errno != 0 && errno != -8 {
                RequestLog.add("BAIDU", step: "建转存目录", detail: "errno=\(errno)，继续尝试", ok: false)
            }
        } catch {
            RequestLog.add("BAIDU", step: "建转存目录", detail: error.localizedDescription, ok: false)
        }
        return Self.transferDir
    }

    // MARK: - 4. locatedownload

    func locatedownload(path: String) async throws -> DirectLink {
        let time = Int(Date().timeIntervalSince1970)
        var items: [(String, String)] = [
            ("method", "locatedownload"),
            ("app_id", Self.appID),
            ("clienttype", "17"),
            ("ver", "4.0"),
            ("ant", "1"), ("check_blue", "1"), ("es", "1"), ("esl", "1"), ("apn_id", "1_-1"),
            ("freeisp", "0"), ("queryfree", "0"), ("use", "1"), ("dtype", "1"), ("eck", "1"), ("ehps", "1"),
            ("err_ver", "1.0"), ("network_type", "WIFI"), ("channel", "0"),
            ("time", "\(time)"),
            ("rand", "5ed606e9da222cde0474cdf70eda884b"),
            ("devuid", "0F1E9FC2E084472DA5A61C4CF4C759AF"),
            ("cuid", "0F1E9FC2E084472DA5A61C4CF4C759AF"),
            ("deviceid", "348642637967375013"),
            ("psign", "860a071f77c860e8cea06e4e54c518f3"),
            ("version", "2.2.111.34"),
            ("version_app", "12.24.6"),
            ("vip", "0"),
            ("path", path)
        ]
        items.removeAll { $0.0 == "path" }
        items.append(("path", path))

        var request = URLRequest(url: url("https://d.pcs.baidu.com/rest/2.0/pcs/file", items))
        request.httpMethod = "POST"
        request.setValue(Self.netdiskUA, forHTTPHeaderField: "User-Agent")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "0".data(using: .utf8)

        let json = try await Net.json(request, platform: "BAIDU", step: "取高速直链")
        try Self.checkErrno(json)
        let candidates = (json["urls"] as? [[String: Any]] ?? []).compactMap { item -> (String, Int)? in
            guard let u = item["url"] as? String, !u.isEmpty else { return nil }
            return (u, (item["encrypt"] as? NSNumber)?.intValue ?? 1)
        }
        let plain = candidates
            .filter { $0.1 == 0 }
            .sorted { lhs, rhs in
                let l = lhs.0.hasPrefix("https") ? 0 : 1
                let r = rhs.0.hasPrefix("https") ? 0 : 1
                return l < r
            }
            .first
        let chosen = plain ?? candidates.first(where: { $0.0.hasPrefix("https") }) ?? candidates.first
        guard let picked = chosen, let dlURL = URL(string: picked.0) else {
            throw AppError.message("取高速直链：没有返回可用地址")
        }
        return DirectLink(url: dlURL, headers: [
            "User-Agent": Self.netdiskUA,
            "Referer": "https://pan.baidu.com/",
            "Cookie": cookie
        ])
    }

    // MARK: - 5. sharedownload（不转存）

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = re.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// sign/timestamp：先用官方 tplconfig 接口，失败再解析分享页 HTML
    func shareSign(state: BaiduShareState) async throws -> (sign: String, timestamp: String) {
        let target = url("https://pan.baidu.com/share/tplconfig", [
            ("surl", state.surl),
            ("fields", "sign,timestamp"),
            ("channel", "chunlei"),
            ("web", "1"),
            ("app_id", Self.appID),
            ("clienttype", "0")
        ])
        var request = URLRequest(url: target)
        request.setValue(Self.webUA, forHTTPHeaderField: "User-Agent")
        request.setValue(withSekey(cookie, state.sekey), forHTTPHeaderField: "Cookie")
        if let json = try? await Net.json(request, platform: "BAIDU", step: "取 sign"),
           let data = json["data"] as? [String: Any],
           let sign = data["sign"] as? String,
           let timestamp = (data["timestamp"] as? NSNumber)?.stringValue ?? (data["timestamp"] as? String) {
            return (sign, timestamp)
        }

        let pageURL = URL(string: "https://pan.baidu.com/s/1\(state.surl)")!
        var pageRequest = URLRequest(url: pageURL)
        pageRequest.setValue(Self.webUA, forHTTPHeaderField: "User-Agent")
        pageRequest.setValue(withSekey(cookie, state.sekey), forHTTPHeaderField: "Cookie")
        let (data, _) = try await URLSession.shared.data(for: pageRequest)
        let html = String(data: data, encoding: .utf8) ?? ""
        guard let sign = firstMatch("\"sign\":\"([0-9A-Za-z]+)\"", in: html),
              let timestamp = firstMatch("\"timestamp\":(\\d+)", in: html) else {
            throw AppError.message("取不到 sign/timestamp（百度页面结构可能变了）")
        }
        return (sign, timestamp)
    }

    func sharedDownload(state: BaiduShareState, fsID: String) async throws -> DirectLink {
        let (sign, timestamp) = try await shareSign(state: state)
        let target = url("https://pan.baidu.com/api/sharedownload", [
            ("sign", sign), ("timestamp", timestamp), ("channel", "chunlei"),
            ("web", "1"), ("app_id", Self.appID), ("clienttype", "0")
        ])
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue(Self.webUA, forHTTPHeaderField: "User-Agent")
        request.setValue(withSekey(cookie, state.sekey), forHTTPHeaderField: "Cookie")
        request.setValue("https://pan.baidu.com/s/1\(state.surl)", forHTTPHeaderField: "Referer")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "encrypt=0&product=share&type=dlink&fid_list=[\(fsID)]".data(using: .utf8)

        let json = try await Net.json(request, platform: "BAIDU", step: "sharedownload")
        try Self.checkErrno(json)
        guard let list = json["list"] as? [[String: Any]],
              let dlink = list.first?["dlink"] as? String,
              let dlURL = URL(string: dlink) else {
            throw AppError.message("sharedownload 没返回 dlink")
        }
        return DirectLink(url: dlURL, headers: [
            "User-Agent": Self.netdiskUA,
            "Referer": "https://pan.baidu.com/",
            "Cookie": withSekey(cookie, state.sekey)
        ])
    }

    // MARK: - 6. 组合

    func resolve(surl: String, pwd: String?) async throws -> (state: BaiduShareState, files: [CloudFile]) {
        var sekey = ""
        if let pwd, !pwd.isEmpty {
            sekey = try await verify(surl: surl, pwd: pwd)
        }
        let result = try await list(surl: surl, sekey: sekey, dir: "/")
        guard !result.shareID.isEmpty, !result.uk.isEmpty else {
            throw AppError.message("百度分享解析失败：没拿到 share_id / uk")
        }
        let state = BaiduShareState(surl: surl, shareID: result.shareID, uk: result.uk, sekey: sekey)
        return (state, result.files)
    }

    /// 优先「建目录 → 转存 → locatedownload」，失败回退 sharedownload
    func direct(state: BaiduShareState, fsID: String) async throws -> DirectLink {
        do {
            let dir = try await ensureTransferDir()
            let path = try await transfer(state: state, fsID: fsID, toDir: dir)
            return try await locatedownload(path: path)
        } catch {
            RequestLog.add("BAIDU", step: "转存链路失败",
                           detail: error.localizedDescription + "，改用 sharedownload", ok: false)
            return try await sharedDownload(state: state, fsID: fsID)
        }
    }

    // MARK: - 错误码

    static func checkErrno(_ json: [String: Any]) throws {
        let errno = (json["errno"] as? NSNumber)?.intValue ?? 0
        guard errno != 0 else { return }
        let message: String
        switch errno {
        case -6: message = "百度未登录或 Cookie 失效（errno=-6），去「账号」重新登录"
        case -9: message = "提取码错误（errno=-9）"
        case -62: message = "触发百度风控，要求验证码（errno=-62），先在浏览器打开一次该分享"
        case 2: message = "参数错误（errno=2），通常是没有 BDCLND 或 bdstoken 失效"
        case 4: message = "请求过于频繁（errno=4）"
        case 112: message = "分享链接已失效（errno=112）"
        case 118: message = "百度限速中（errno=118），稍后再试"
        case 31066: message = "文件不存在（errno=31066）"
        default: message = "百度返回 errno=\(errno)"
        }
        throw AppError.message(message)
    }
}
