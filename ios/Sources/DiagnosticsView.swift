import SwiftUI
import UIKit

struct CookieStatus: Identifiable {
    let platform: Platform
    let text: String
    var id: String { platform.rawValue }
}

/// 诊断页：出问题时把这里的内容截图/复制发出来，就能定位是哪一步挂了
struct DiagnosticsView: View {
    @State private var entries: [RequestLogEntry] = []
    @State private var statuses: [CookieStatus] = []
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section("账号状态") {
                    if statuses.isEmpty {
                        Text("还没有保存任何 Cookie").font(.footnote).foregroundColor(.secondary)
                    }
                    ForEach(statuses) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.platform.title).font(.subheadline)
                            Text(item.text).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }

                if !CookieStore.lastError.isEmpty {
                    Section("存储提示") {
                        Text(CookieStore.lastError).font(.caption).foregroundColor(.orange)
                    }
                }

                Section {
                    if entries.isEmpty {
                        Text("还没有请求记录").font(.footnote).foregroundColor(.secondary)
                    }
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.ok ? "OK" : "ERR")
                                    .font(.caption2.bold())
                                    .foregroundColor(entry.ok ? .green : .red)
                                Text("\(entry.platform) · \(entry.step)")
                                    .font(.caption)
                                Spacer()
                                Text(entry.time, style: .time)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text(entry.detail)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("最近请求（最新在上）")
                } footer: {
                    Text("截图这一段发给开发者，就能看出是哪一步、哪个域名、什么状态码出错。")
                }
            }
            .navigationTitle("诊断")
            .toolbar {
                Button("刷新") { reload() }
                Button(copied ? "已复制" : "复制全部") {
                    UIPasteboard.general.string = report()
                    copied = true
                }
            }
            .onAppear { reload() }
        }
    }

    private func reload() {
        entries = RequestLog.snapshot()
        statuses = Platform.allCases.map { platform in
            guard let cookie = CookieStore.load(platform) else {
                return CookieStatus(platform: platform, text: "未配置")
            }
            let missing = CookieStore.missingKey(cookie, for: platform)
            let state = missing == nil ? "已配置且含登录字段" : "已配置，但缺少 \(missing!)"
            return CookieStatus(platform: platform, text: "\(cookie.count) 字符 · \(state)")
        }
        copied = false
    }

    private func report() -> String {
        var lines: [String] = ["=== 账号 ==="]
        for item in statuses {
            lines.append("\(item.platform.rawValue): \(item.text)")
        }
        lines.append("=== 请求 ===")
        lines.append(RequestLog.text())
        return lines.joined(separator: "\n")
    }
}
