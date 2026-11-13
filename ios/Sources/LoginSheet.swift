import SwiftUI
import WebKit

/// 包一层 WKWebView，给登录页提供 后退/刷新/跳到登录区
final class WebController: ObservableObject {
    weak var webView: WKWebView?
    @Published var canBack = false
    @Published var canForward = false
    @Published var loading = false

    func back() { webView?.goBack() }
    func forward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func load(_ url: URL) { webView?.load(URLRequest(url: url)) }

    /// 夸克页面是营销页 + 登录卡片，直接滚到「登录账号」区域
    func scrollToAnchor(_ anchor: String) {
        let js = """
        (function(){
          var el = document.getElementById('\(anchor)');
          if (!el) {
            var all = document.querySelectorAll('div,section,span,h1,h2,h3');
            for (var i = 0; i < all.length; i++) {
              if ((all[i].textContent || '').trim() === '\(anchor)') { el = all[i]; break; }
            }
          }
          if (el) { el.scrollIntoView({block: 'center'}); }
        })();
        """
        webView?.evaluateJavaScript(js)
    }
}

struct LoginSheet: View {
    let platform: Platform
    let onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = WebController()
    @State private var progress = 0.0
    @State private var capturing = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 18) {
                    Button { controller.back() } label: { Image(systemName: "chevron.left") }
                        .disabled(!controller.canBack)
                    Button { controller.forward() } label: { Image(systemName: "chevron.right") }
                        .disabled(!controller.canForward)
                    Button { controller.reload() } label: { Image(systemName: "arrow.clockwise") }
                    Button("首页") {
                        if let home = URL(string: platform.referer) { controller.load(home) }
                    }
                    .font(.caption)
                    Spacer()
                    if let anchor = platform.loginAnchor {
                        Button("跳到登录区") { controller.scrollToAnchor(anchor) }
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)

                ZStack(alignment: .top) {
                    WebView(url: platform.loginURL,
                            progress: $progress,
                            controller: controller,
                            userAgent: platform.webBrowserUA,
                            onCookies: { cookies in
                                let header = Self.header(from: cookies, platform: platform)
                                if !header.isEmpty {
                                    CookieStore.save(header, for: platform)
                                }
                            })
                    if progress < 1.0 {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.accentColor)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message ?? platform.loginHint)
                        .font(.caption)
                        .foregroundColor(message == nil ? .secondary : .orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(.thinMaterial)
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
                    message = "抓到 \(header.count) 字符，但缺少登录字段 \(missing)——说明还没真正登录成功。"
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
    var controller: WebController?
    var userAgent: String?
    var onCookies: ([HTTPCookie]) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(progress: $progress, onCookies: onCookies, controller: controller)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        if let userAgent {
            webView.customUserAgent = userAgent
        }
        webView.navigationDelegate = context.coordinator
        context.coordinator.attach(webView)
        controller?.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let progress: Binding<Double>
        private let onCookies: ([HTTPCookie]) -> Void
        private weak var controller: WebController?
        private var observations: [NSKeyValueObservation] = []

        init(progress: Binding<Double>, onCookies: @escaping ([HTTPCookie]) -> Void, controller: WebController?) {
            self.progress = progress
            self.onCookies = onCookies
            self.controller = controller
        }

        func attach(_ webView: WKWebView) {
            observations.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async {
                    self?.progress.wrappedValue = view.estimatedProgress
                }
            })
            observations.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async {
                    self?.controller?.canBack = view.canGoBack
                }
            })
            observations.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async {
                    self?.controller?.canForward = view.canGoForward
                }
            })
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                self?.onCookies(cookies)
            }
            DispatchQueue.main.async {
                self.controller?.canBack = webView.canGoBack
                self.controller?.canForward = webView.canGoForward
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.controller?.canBack = webView.canGoBack
                self.controller?.canForward = webView.canGoForward
            }
        }
    }
}

