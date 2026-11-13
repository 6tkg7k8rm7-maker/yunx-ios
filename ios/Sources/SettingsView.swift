import SwiftUI

struct SettingsView: View {
    @State private var platform: Platform = .quark
    @State private var input = ""
    @State private var toast = false
    @State private var showLogin = false
    @State private var savedCookie: String?
    @FocusState private var cookieFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("平台", selection: $platform) {
                        ForEach(Platform.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("网盘")
                }

                Section {
                    if let cookie = savedCookie {
                        let missing = CookieStore.missingKey(cookie, for: platform)
                        Text("已保存 \(cookie.count) 字符：\(cookie.prefix(20))…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if let missing {
                            Text("缺少登录字段 \(missing)，这份 Cookie 不可用，请重新登录")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    } else {
                        Text("未配置（夸克/UC/百度取直链必须登录）")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if !CookieStore.lastError.isEmpty {
                        Text(CookieStore.lastError).font(.caption2).foregroundColor(.orange)
                    }

                    Button {
                        showLogin = true
                    } label: {
                        Label("用内置浏览器登录 \(platform.title)", systemImage: "safari")
                    }

                    TextEditor(text: $input)
                        .frame(minHeight: 88)
                        .font(.caption)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($cookieFocused)

                    HStack {
                        Button("保存 Cookie") {
                            CookieStore.save(input, for: platform)
                            input = ""
                            reload()
                            toast = true
                        }
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Spacer()
                        Button("清除", role: .destructive) {
                            CookieStore.clear(platform)
                            reload()
                            toast = true
                        }
                    }
                } header: {
                    Text("凭证")
                } footer: {
                    Text("登录后会自动抓取；也可从电脑浏览器复制整行 Cookie 粘贴。Cookie 存 Keychain，只在本机。百度要包含 BDUSS。")
                }

                Section {
                    Text("支持：夸克网盘、UC 网盘、百度网盘（分享解析 + 取直链 + 下载）")
                        .font(.caption)
                    Text("百度风控较严：同一账号短时间内大量取链容易触发限速（errno=118）或验证码（-62），建议小批量下载。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("下载保存位置：文件 App › 我的 iPhone › 云析")
                        .font(.caption)
                } header: {
                    Text("说明")
                }
            }
            .navigationTitle("账号")
            .keyboardDoneButton($cookieFocused)
            .onChange(of: platform) { _ in
                input = ""
                reload()
            }
            .onAppear { reload() }
            .sheet(isPresented: $showLogin) {
                LoginSheet(platform: platform) {
                    showLogin = false
                    reload()
                }
            }
            .alert("已更新", isPresented: $toast) {
                Button("好", role: .cancel) {}
            }
        }
    }

    private func reload() {
        savedCookie = CookieStore.load(platform)
    }
}
