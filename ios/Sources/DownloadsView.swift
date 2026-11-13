import SwiftUI

struct DownloadsView: View {
    @ObservedObject private var downloader = Downloader.shared

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
                Button("清理已完成") { downloader.clearFinished() }
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
            if let url = task.fileURL {
                HStack(spacing: 14) {
                    ShareLink(item: url) {
                        Label("导出到「文件」", systemImage: "square.and.arrow.up")
                            .font(.caption)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        downloader.delete(task)
                    } label: {
                        Image(systemName: "trash").font(.caption)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
