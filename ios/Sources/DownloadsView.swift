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
