import SwiftUI
import UIKit

struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct DownloadsView: View {
    @ObservedObject private var downloader = Downloader.shared
    @State private var share: SharePayload?

    var body: some View {
        NavigationStack {
            List {
                if downloader.tasks.isEmpty {
                    Text("还没有下载任务")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                ForEach(downloader.tasks) { task in
                    row(task)
                }
            }
            .navigationTitle("下载")
            .toolbar {
                Button("清理已结束") { downloader.clearFinished() }
            }
            .sheet(item: $share) { payload in
                ActivityView(items: [payload.url])
            }
            .safeAreaInset(edge: .bottom) {
                Text("文件位置：文件 App › 我的 iPhone › 云析")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.thinMaterial)
            }
        }
    }

    @ViewBuilder
    private func row(_ task: DlTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.name)
                    .font(.subheadline)
                    .lineLimit(2)
                Spacer()
                Text(task.state)
                    .font(.caption)
                    .foregroundColor(task.state == "失败" ? .red : .secondary)
            }

            ProgressView(value: task.progress)

            HStack {
                if task.total > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: task.total, countStyle: .file))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if !task.speed.isEmpty {
                    Text(task.speed)
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                }
            }

            if let error = task.error {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
            }

            HStack(spacing: 10) {
                if task.fileURL != nil {
                    Button {
                        if let url = task.fileURL { share = SharePayload(url: url) }
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.up").font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                } else if task.paused {
                    Button {
                        downloader.resume(task)
                    } label: {
                        Label("继续", systemImage: "play.fill").font(.caption)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        downloader.pause(task)
                    } label: {
                        Label("暂停", systemImage: "pause.fill").font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .disabled(task.state == "已完成" || task.state == "失败")
                }

                Button(role: .destructive) {
                    downloader.remove(task)
                } label: {
                    Label("删除", systemImage: "trash").font(.caption)
                }
                .buttonStyle(.bordered)

                Spacer()
            }
        }
        .padding(.vertical, 6)
    }
}
