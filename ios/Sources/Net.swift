import Foundation

/// 极简 HTTP 封装：手动带 Cookie / UA / Referer，不依赖 URLSession 的 Cookie 存储。
enum Net {

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 300
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    static func json(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AppError.message("网络错误：\(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw AppError.message("网络无响应")
        }
        guard (200..<400).contains(http.statusCode) else {
            throw AppError.message("HTTP \(http.statusCode)")
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let obj = raw as? [String: Any] else {
            throw AppError.message("返回不是 JSON（可能被风控拦截）")
        }
        return obj
    }

    /// 夸克/UC 用业务状态码表达错误，HTTP 仍是 200
    static func check(_ json: [String: Any]) throws {
        let status = (json["status"] as? NSNumber)?.intValue ?? 200
        let code = (json["code"] as? NSNumber)?.intValue ?? 0
        guard status == 200, code == 0 else {
            let msg = (json["message"] as? String) ?? "接口返回异常（\(status)）"
            throw AppError.message(msg)
        }
    }
}
