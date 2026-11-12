import Combine
import Foundation
import UIKit

struct DlTask: Identifiable {
    let id: UUID
    var name: String
    var progress: Double
    var state: String
    var fileURL: URL?
    var error: String?
}

/// 下载器：直链带 Referer/Cookie，落到 App 的 Documents（文件 App 里可见）。
final class Downloader: NSObject, ObservableObject, URLSessionDownloadDelegate {

    static let shared = Downloader()

    @Published private(set) var tasks: [DlTask] = []

    private var uuids: [Int: UUID] = [:]
    private var names: [Int: String] = [:]
    private let lock = NSLock()
    private var backgroundID: UIBackgroundTaskIdentifier = .invalid

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 60 * 60 * 6
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    // MARK: - 对外

    func start(name: String, link: DirectLink) {
        var request = URLRequest(url: link.url)
        for (key, value) in link.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let task = session.downloadTask(with: request)
        let uuid = UUID()
        let safeName = Downloader.sanitize(name)
        lock.lock()
        uuids[task.taskIdentifier] = uuid
        names[task.taskIdentifier] = safeName
        lock.unlock()
        DispatchQueue.main.async {
            self.tasks.insert(DlTask(id: uuid, name: safeName, progress: 0,
                                     state: "下载中", fileURL: nil, error: nil), at: 0)
            self.keepAlive()
        }
        task.resume()
    }

    func clearFinished() {
        tasks.removeAll { $0.state == "已完成" || $0.state == "失败" }
    }

    func delete(_ task: DlTask) {
        if let url = task.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        tasks.removeAll { $0.id == task.id }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let uuid = uuid(for: downloadTask.taskIdentifier) else { return }
        let ratio: Double = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        DispatchQueue.main.async {
            if let index = self.tasks.firstIndex(where: { $0.id == uuid }) {
                self.tasks[index].progress = min(max(ratio, 0), 0.995)
            }
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let key = downloadTask.taskIdentifier
        guard let uuid = uuid(for: key), let fileName = name(for: key) else { return }
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dest = docs.appendingPathComponent(fileName)
        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: location, to: dest)
            DispatchQueue.main.async {
                if let index = self.tasks.firstIndex(where: { $0.id == uuid }) {
                    self.tasks[index].progress = 1
                    self.tasks[index].state = "已完成"
                    self.tasks[index].fileURL = dest
                }
                self.releaseIfIdle()
            }
        } catch {
            let message = "保存失败：\(error.localizedDescription)"
            DispatchQueue.main.async {
                if let index = self.tasks.firstIndex(where: { $0.id == uuid }) {
                    self.tasks[index].state = "失败"
                    self.tasks[index].error = message
                }
                self.releaseIfIdle()
            }
        }
        forget(key)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let key = task.taskIdentifier
        guard let error = error, let uuid = uuid(for: key) else {
            forget(key)
            return
        }
        DispatchQueue.main.async {
            if let index = self.tasks.firstIndex(where: { $0.id == uuid }) {
                self.tasks[index].state = "失败"
                self.tasks[index].error = error.localizedDescription
            }
            self.releaseIfIdle()
        }
        forget(key)
    }

    // MARK: - 内部

    private func uuid(for key: Int) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return uuids[key]
    }

    private func name(for key: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return names[key]
    }

    private func forget(_ key: Int) {
        lock.lock()
        uuids.removeValue(forKey: key)
        names.removeValue(forKey: key)
        lock.unlock()
    }

    private func keepAlive() {
        guard backgroundID == .invalid else { return }
        backgroundID = UIApplication.shared.beginBackgroundTask(withName: "yunx.download") { [weak self] in
            guard let self = self else { return }
            UIApplication.shared.endBackgroundTask(self.backgroundID)
            self.backgroundID = .invalid
        }
    }

    private func releaseIfIdle() {
        let running = tasks.contains { $0.state == "下载中" }
        if !running, backgroundID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundID)
            backgroundID = .invalid
        }
    }

    static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var cleaned = name.components(separatedBy: invalid).joined(separator: "_")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { cleaned = "未命名文件" }
        if cleaned.count > 180 { cleaned = String(cleaned.prefix(180)) }
        return cleaned
    }
}
