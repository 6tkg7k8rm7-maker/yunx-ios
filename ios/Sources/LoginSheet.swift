import SwiftUI
import WebKit

struct LoginSheet: View {
    let platform: Platform
    let onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var progress = 0.0
    @State private var capturing = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                WebView(url: platform.loginURL,
                        progress: $progress,
                        onCookies: { cookies in
                            // 每次页面加载完都顺手抓一次，避免用户点「完成」时还没同步
                            let header = Self.header(from: cookies, platform: platform)
                            if !header.isEmpty {
                                CookieStore.save(header, for: platform)
                            }
                        })
                    .ignoresSafeArea(edges: .bottom)
                if progress < 1.0 {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(.thinMaterial)
                }
            }
            .navigationTitle("登录 \(platform.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(capturing ? "抓取中…" : "完成") { capture() }
                        .disabled(capturing)
                }
            }
        }
    }

    private func capture() {
        capturing = true
        message = nil
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { webCookies in
            var all = webCookies
            if let shared = HTTPCookieStorage.shared.cookies {
                all.append(contentsOf: shared)
            }
            let header = Self.header(from: all, platform: platform)
            DispatchQueue.main.async {
                capturing = false
                guard !header.isEmpty else {
                    message = "没抓到 \(platform.title) 的 Cookie。请在页面里完成登录后再点「完成」。"
                    return
                }
                if let missing = CookieStore.missingKey(header, for: platform) {
                    message = "抓到了 Cookie，但缺少登录态字段 \(missing)，可能还没登录成功。"
                    CookieStore.save(header, for: platform)
                    return
                }
                CookieStore.save(header, for: platform)
                onFinish()
                dismiss()
            }
        }
    }

    private static func header(from cookies: [HTTPCookie], platform: Platform) -> String {
        var seen = Set<String>()
        var parts: [String] = []
        for cookie in cookies where cookie.domain.contains(platform.cookieHost) {
            if seen.contains(cookie.name) { continue }
            seen.insert(cookie.name)
            parts.append("\(cookie.name)=\(cookie.value)")
        }
        return parts.joined(separator: "; ")
    }
}

struct WebView: UIViewRepresentable {
    let url: URL
    @Binding var progress: Double
    var onCookies: ([HTTPCookie]) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(progress: $progress, onCookies: onCookies)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.startObserving(webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let progress: Binding<Double>
        private let onCookies: ([HTTPCookie]) -> Void
        private var observation: NSKeyValueObservation?

        init(progress: Binding<Double>, onCookies: @escaping ([HTTPCookie]) -> Void) {
            self.progress = progress
            self.onCookies = onCookies
        }

        func startObserving(_ webView: WKWebView) {
            observation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async {
                    self?.progress.wrappedValue = view.estimatedProgress
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                self?.onCookies(cookies)
            }
        }
    }
}
