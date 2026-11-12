import Foundation

/// 夸克 / UC 通用客户端：token → detail 列表 → save 转存 → task 轮询 → file/download 取直链
struct QuarkClient {

    let platform: Platform
    let cookie: String

    // MARK: - 基础请求

    private func makeURL(_ path: String, _ query: [String: String] = [:]) -> URL {
        var comp = URLComponents(string: platform.apiBase + path)!
        if !query.isEmpty {
            comp.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return comp.url!
    }

    private func decorate(_ request: inout URLRequest) {
        request.setValue(platform.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(platform.referer, forHTTPHeaderField: "Referer")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
    }

    private func get(_ path: String, _ query: [String: String] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: makeURL(path, query))
        decorate(&request)
        let json = try await Net.json(request)
        try Net.check(json)
        return json
    }

    private func post(_ path: String,
                      _ query: [String: String] = [:],
                      _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: makeURL(path, query))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        decorate(&request)
        let json = try await Net.json(request)
        try Net.check(json)
        return json
    }

    // MARK: - 业务

    /// 取分享 stoken（提取码不对会在这里报错）
    func stoken(shareID: String, pwd: String?) async throws -> String {
        let json = try await post(
            "/1/clouddrive/share/sharepage/token",
            ["pr": "ucpro", "fr": "pc"],
            ["pwd_id": shareID, "passcode": pwd ?? ""]
        )
        guard let data = json["data"] as? [String: Any],
              let token = data["stoken"] as? String, !token.isEmpty else {
            throw AppError.message("取 token 失败：分享不存在、提取码错误或需要登录")
        }
        return token
    }

    /// 列目录，pdirFid = "0" 为根目录
    func list(shareID: String, stoken: String, pdirFid: String = "0") async throws -> [CloudFile] {
        var result: [CloudFile] = []
        var page = 1
        while page <= 20 {
            let json = try await get("/1/clouddrive/share/sharepage/detail", [
                "pr": "ucpro",
                "fr": "pc",
                "pwd_id": shareID,
                "stoken": stoken,
                "pdir_fid": pdirFid,
                "force": "0",
                "_page": "\(page)",
                "_size": "50",
                "_fetch_banner": "1",
                "_fetch_share": "1",
                "_fetch_total": "1",
                "_sort": "file_type:asc,updated_at:desc"
            ])
            let data = json["data"] as? [String: Any] ?? [:]
            let items = data["list"] as? [[String: Any]] ?? []
            for item in items {
                let fid = item["fid"] as? String ?? ""
                guard !fid.isEmpty else { continue }
                result.append(CloudFile(
                    fid: fid,
                    shareToken: item["share_fid_token"] as? String ?? "",
                    name: item["file_name"] as? String ?? "未命名",
                    size: (item["size"] as? NSNumber)?.int64Value ?? 0,
                    isDir: (item["dir"] as? NSNumber)?.boolValue ?? (item["dir"] as? Bool ?? false)
                ))
            }
            if items.count < 50 { break }
            page += 1
        }
        return result
    }

    /// 转存到自己网盘后取直链（夸克必须先落盘）
    func direct(shareID: String, stoken: String, file: CloudFile) async throws -> DirectLink {
        let saveJSON = try await post(
            "/1/clouddrive/share/sharepage/save",
            ["pr": "ucpro", "fr": "pc"],
            [
                "fid_list": [file.fid],
                "fid_token_list": [file.shareToken],
                "to_pdir_fid": "0",
                "pwd_id": shareID,
                "stoken": stoken,
                "pdir_fid": "0",
                "scene": "link"
            ]
        )
        guard let taskID = (saveJSON["data"] as? [String: Any])?["task_id"] as? String else {
            throw AppError.message("转存失败，可能是空间不足或账号被风控")
        }

        var savedFid = ""
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 600_000_000)
            let taskJSON = try await get("/1/clouddrive/task", [
                "pr": "ucpro", "fr": "pc", "task_id": taskID, "retry_index": "0"
            ])
            let data = taskJSON["data"] as? [String: Any] ?? [:]
            let saveAs = data["save_as"] as? [String: Any] ?? [:]
            if let fids = saveAs["save_as_top_fids"] as? [String],
               let first = fids.first, !first.isEmpty {
                savedFid = first
                break
            }
            let status = (data["status"] as? NSNumber)?.intValue ?? 0
            if status == 3 { break }
        }
        guard !savedFid.isEmpty else {
            throw AppError.message("转存任务未完成，稍后重试")
        }

        let dlJSON = try await post(
            "/1/clouddrive/file/download",
            ["pr": "ucpro", "fr": "pc", "sys": "win32", "ve": "3.23.2"],
            ["fids": [savedFid]]
        )
        guard let arr = dlJSON["data"] as? [[String: Any]],
              let urlText = arr.first?["download_url"] as? String,
              let url = URL(string: urlText) else {
            throw AppError.message("取直链失败（链接可能已过期）")
        }
        return DirectLink(url: url, headers: [
            "Referer": platform.referer,
            "User-Agent": platform.userAgent,
            "Cookie": cookie
        ])
    }
}
