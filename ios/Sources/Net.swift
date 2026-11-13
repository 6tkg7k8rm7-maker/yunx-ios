import Foundation

/// 最近请求日志：出问题时能在 App 里直接看到哪一步挂了（不用连电脑）
struct RequestLogEntry: Identifiable {
    let id = UUID()
    let time: Date
    let platform: String
    let step: String
    let detail: String
    let ok: Bool
}

enum RequestLog {
    private static let queue = DispatchQueue(label: "yunx.log")
    private static var storage: [RequestLogEntry] = []

    static func add(_ platform: String, step: String, detail: String, ok: Bool) {
        let entry = RequestLogEntry(time: Date(), platform: platform, step: step, detail: detail, ok: ok)
        queue.async {
            storage.insert(entry, at: 0)
            if storage.count > 120 { storage.removeLast(storage.count - 120) }
        }
    }

    static func snapshot() -> [RequestLogEntry] {
        queue.sync { storage }
    }

    static func clear() {
        queue.async { storage.removeAll() }
    }

    static func text() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return snapshot().map { e in
            "[\(fmt.string(from: e.time))] [\(e.ok ? "OK" : "ERR")] \(e.platform)/\(e.step) \(e.detail)"
        }.joined(separator: "\n")
    }
}

/// 极简 HTTP 封装：手动带 Cookie / UA / Referer，不依赖 URLSession 的 Cookie 存储。
enum Net {

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 300
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// 发请求并解析 JSON；失败时把 HTTP 状态/响应片段写进日志
    static func json(_ request: URLRequest, platform: String, step: String) async throws -> [String: Any] {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.absoluteString ?? "?"
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            RequestLog.add(platform, step: step, detail: "\(method) \(path) -> \(error.localizedDescription)", ok: false)
            throw AppError.message("\(step)：\(error.localizedDescription)")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let obj = raw as? [String: Any] else {
            let snippet = String(data: data.prefix(180), encoding: .utf8) ?? ""
            RequestLog.add(platform, step: step, detail: "\(method) \(path) -> HTTP \(code) 非JSON: \(snippet)", ok: false)
            throw AppError.message("\(step)：返回不是 JSON（HTTP \(code)）")
        }
        let errno = (obj["errno"] as? NSNumber)?.intValue
            ?? (obj["status"] as? NSNumber)?.intValue
            ?? (obj["code"] as? NSNumber)?.intValue
        RequestLog.add(platform, step: step,
                       detail: "\(method) \(path) -> HTTP \(code) errno=\(errno.map(String.init) ?? "-")",
                       ok: code < 400)
        guard (200..<400).contains(code) else {
            throw AppError.message("\(step)：HTTP \(code)")
        }
        return obj
    }

    /// 夸克 / UC 用业务状态码表达错误，HTTP 仍是 200
    static func check(_ json: [String: Any], step: String) throws {
        let status = (json["status"] as? NSNumber)?.intValue ?? 200
        let code = (json["code"] as? NSNumber)?.intValue ?? 0
        guard status == 200, code == 0 else {
            let msg = (json["message"] as? String) ?? "接口返回异常（\(status)）"
            throw AppError.message("\(step)：\(msg)")
        }
    }
}
