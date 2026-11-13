import SwiftUI
import WebKit

struct WebURL: Identifiable {
    let id = UUID()
    let url: URL
}

/// 百度网页下载：直接跑百度自己的分享页，点页面里的「下载」，
/// 由百度前端自己算 sign/dlink，我们只截获下载并落盘。比逆向接口稳。
struct BaiduWebSheet: View {
    let url: URL
    let onSaved: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var message = "在页面里点「下载」，文件会直接存到 App 里"
    @State private var done = 0

    var body: some View {
        NavigationStack {
            BaiduWebView(url: url) { name in
                done += 1
                message = "已保存：\(name)"
                onSaved(name)
            }
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .bottom) {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.thinMaterial)
            }
            .navigationTitle("百度分享页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if done > 0 {
                        Text("\(done) 个文件").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

struct BaiduWebView: UIViewRepresentable {
    let url: URL
    let onSaved: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSaved: onSaved)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKDownloadDelegate {
        weak var webView: WKWebView?
        private let onSaved: (String) -> Void

        init(onSaved: @escaping (String) -> Void) {
            self.onSaved = onSaved
        }

        // MARK: 导航拦截

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download)
                return
            }
            if let target = navigationAction.request.url, Self.isPcsHost(target) {
                decisionHandler(.cancel)
                startOwnDownload(target)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.canShowMIMEType {
                decisionHandler(.allow)
            } else {
                decisionHandler(.download)
            }
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        // MARK: 下载落盘

        func download(_ download: WKDownload,
                      decideDestinationUsing response: URLResponse,
                      suggestedFilename: String) async -> URL? {
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                return nil
            }
            let name = Downloader.sanitize(suggestedFilename.isEmpty ? "百度下载文件" : suggestedFilename)
            let dest = docs.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            return dest
        }

        func downloadDidFinish(_ download: WKDownload) {
            let name = download.originalRequest?.url?.lastPathComponent ?? "文件"
            onSaved(name)
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            // 失败交给页面自己重试
        }

        // MARK: 直链兜底

        private static func isPcsHost(_ url: URL) -> Bool {
            guard let host = url.host?.lowercased() else { return false }
            return host.contains("baidupcs.com")
                || host.contains("pcs.baidu.com")
                || host.contains("d.pcs.baidu.com")
        }

        /// 页面直接把 dlink 当导航发起时，用自己的下载器接住（带 Cookie/Referer）
        private func startOwnDownload(_ url: URL) {
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                let header = cookies.filter { $0.domain.contains("baidu.com") }
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                let link = DirectLink(url: url, headers: [
                    "User-Agent": "netdisk;12.24.6;piano;android-android;16;JSbridge4.4.0;jointBridge;1.1.0",
                    "Referer": "https://pan.baidu.com/",
                    "Cookie": header
                ])
                DispatchQueue.main.async {
                    Downloader.shared.start(name: url.lastPathComponent, link: link)
                    self.onSaved(url.lastPathComponent)
                }
            }
        }
    }
}
