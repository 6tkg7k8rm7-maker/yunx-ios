import SwiftUI
import UIKit

struct ContentView: View {
    var body: some View {
        TabView {
            ResolveView()
                .tabItem { Label("解析", systemImage: "link") }
            DownloadsView()
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }
            SettingsView()
                .tabItem { Label("账号", systemImage: "person.crop.circle") }
            DiagnosticsView()
                .tabItem { Label("诊断", systemImage: "stethoscope") }
        }
    }
}

struct FileRow: View {
    let file: CloudFile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.iconName)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .lineLimit(2)
                    .font(.subheadline)
                Text(file.sizeText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if !file.isDir {
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct ResolveView: View {
    @State private var text = ""
    @State private var context: DriveContext?
    @State private var files: [CloudFile] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var showLogin = false
    @State private var loginPlatform: Platform = .quark
    @FocusState private var linkFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("粘贴分享链接，可带提取码", text: $text, axis: .vertical)
                        .lineLimit(1...3)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($linkFocused)
                    HStack {
                        Button {
                            if let clip = UIPasteboard.general.string { text = clip }
                        } label: {
                            Label("粘贴", systemImage: "doc.on.clipboard")
                        }
                        Spacer()
                        Button {
                            Task { await resolve() }
                        } label: {
                            if loading { ProgressView() } else { Text("解析") }
                        }
                        .disabled(loading || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text("分享链接")
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }

                if let context {
                    Section {
                        ForEach(files) { file in
                            if file.isDir {
                                NavigationLink {
                                    FolderView(context: context, dirID: file.fid, title: file.name)
                                } label: {
                                    FileRow(file: file)
                                }
                            } else {
                                Button {
                                    Task { await download(file, context: context) }
                                } label: {
                                    FileRow(file: file)
                                }
                            }
                        }
                    } header: {
                        Text("\(context.platform.title) · \(files.count) 项")
                    } footer: {
                        Text("点文件开始下载；完成后到「下载」页导出到「文件」App。")
                    }
                }
            }
            .navigationTitle("云析")
            .keyboardDoneButton($linkFocused)
            .sheet(isPresented: $showLogin) {
                LoginSheet(platform: loginPlatform) { showLogin = false }
            }
        }
    }

    @MainActor
    private func resolve() async {
        errorText = nil
        guard let parsed = ShareParser.parse(text) else {
            errorText = "没识别出链接（只支持夸克 / UC 分享链接）"
            return
        }
        let cookie = CookieStore.load(parsed.platform) ?? ""
        guard !cookie.isEmpty else {
            loginPlatform = parsed.platform
            showLogin = true
            errorText = "先登录 \(parsed.platform.title)，或在「账号」页粘贴 Cookie"
            return
        }
        if let missing = CookieStore.missingKey(cookie, for: parsed.platform) {
            loginPlatform = parsed.platform
            showLogin = true
            errorText = "Cookie 里缺少登录字段 \(missing)，请重新登录一次（现在的 Cookie 不是登录态）"
            return
        }
        loading = true
        defer { loading = false }
        do {
            let client = QuarkClient(platform: parsed.platform, cookie: cookie)
            let stoken = try await client.stoken(shareID: parsed.shareID, pwd: parsed.pwd)
            let list = try await client.list(shareID: parsed.shareID, stoken: stoken)
            context = DriveContext(platform: parsed.platform,
                                   cookie: cookie,
                                   state: .quark(shareID: parsed.shareID, stoken: stoken))
            files = list
            if list.isEmpty { errorText = "分享里没有文件" }
        } catch {
            context = nil
            files = []
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func download(_ file: CloudFile, context: DriveContext) async {
        errorText = nil
        do {
            let link = try await makeDrive(context).direct(file)
            Downloader.shared.start(name: file.name, link: link)
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct FolderView: View {
    let context: DriveContext
    let dirID: String
    let title: String

    @State private var files: [CloudFile] = []
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        List {
            if loading {
                HStack { ProgressView(); Text("加载中…").foregroundColor(.secondary) }
            }
            if let errorText {
                Text(errorText).font(.footnote).foregroundColor(.red)
            }
            ForEach(files) { file in
                if file.isDir {
                    NavigationLink {
                        FolderView(context: context, dirID: file.fid, title: file.name)
                    } label: {
                        FileRow(file: file)
                    }
                } else {
                    Button {
                        Task { await download(file) }
                    } label: {
                        FileRow(file: file)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            files = try await makeDrive(context).list(dirID: dirID)
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func download(_ file: CloudFile) async {
        do {
            let link = try await makeDrive(context).direct(file)
            Downloader.shared.start(name: file.name, link: link)
        } catch {
            errorText = error.localizedDescription
        }
    }
}
