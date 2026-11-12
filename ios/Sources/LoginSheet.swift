import SwiftUI
import WebKit

struct LoginSheet: View {
    let platform: Platform
    let onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var progress = 0.0
    @State private var capturing = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                WebView(url: platform.loginURL, progress: $progress)
                    .ignoresSafeArea(edges: .bottom)
                if progress < 1.0 {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
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

    /// 登录完成时把该域名下的 Cookie 拼成请求头存进 Keychain
    private func capture() {
        capturing = true
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let matched = cookies.filter { $0.domain.contains(platform.cookieHost) }
            let header = matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            DispatchQueue.main.async {
                capturing = false
                if !header.isEmpty {
                    CookieStore.save(header, for: platform)
                }
                onFinish()
                dismiss()
            }
        }
    }
}

struct WebView: UIViewRepresentable {
    let url: URL
    @Binding var progress: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(progress: $progress)
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
        private var observation: NSKeyValueObservation?

        init(progress: Binding<Double>) {
            self.progress = progress
        }

        func startObserving(_ webView: WKWebView) {
            observation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async {
                    self?.progress.wrappedValue = view.estimatedProgress
                }
            }
        }
    }
}
