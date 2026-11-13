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
    var speed: String = ""
    var total: Int64 = 0
}

/// 多连接分片下载：
/// 先探测大小与 Range 支持，支持就切成若干段并发拉，最后按顺序合并成一个文件；
/// 不支持 Range（或文件很小）就退回单连接。文件落在 App 的 Documents，文件 App 里可见。
final class Downloader: NSObject, ObservableObject, URLSessionDownloadDelegate {

    static let shared = Downloader()

    /// 并发分片数（可在设置页改）
    var connections: Int = 6

    @Published private(set) var tasks: [DlTask] = []

    private struct PartRef {
        let id: UUID
        let index: Int
    }

    private var refs: [Int: PartRef] = [:]
    private var partFiles: [UUID: [Int: URL]] = [:]
    private var partRanges: [UUID: [ClosedRange<Int64>]] = [:]
    private var received: [UUID: [Int: Int64]] = [:]
    private var totals: [UUID: Int64] = [:]
    private var lastSpeed: [UUID: (time: Date, bytes: Int64)] = [:]
    private var started: [UUID: (name: String, url: URL, headers: [String: String], dir: URL)] = [:]
    private let lock = NSLock()
    private var backgroundID: UIBackgroundTaskIdentifier = .invalid

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 60 * 60 * 6
        cfg.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    // MARK: - 对外

    func start(name: String, link: DirectLink) {
        let id = UUID()
        let safe = Downloader.sanitize(name)
        DispatchQueue.main.async {
            self.tasks.insert(DlTask(id: id, name: safe, progress: 0, state: "准备中", fileURL: nil, error: nil), at: 0)
            self.keepAlive()
        }
        Task { await self.begin(id: id, name: safe, link: link) }
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

    // MARK: - 流程

    private func begin(id: UUID, name: String, link: DirectLink) async {
        let probe = await probe(link: link)
        let size = probe.size
        let useParts = probe.ranged && size > 2 * 1024 * 1024

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(id.uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        lock.lock()
        started[id] = (name: name, url: link.url, headers: link.headers, dir: dir)
        totals[id] = size
        lock.unlock()

        if useParts {
            let count = max(2, min(connections, 8))
            var ranges: [ClosedRange<Int64>] = []
            let chunk = size / Int64(count)
            var start: Int64 = 0
            for index in 0..<count {
                let end = index == count - 1 ? size - 1 : start + chunk - 1
                ranges.append(start...end)
                start = end + 1
            }
            lock.lock()
            partRanges[id] = ranges
            var map: [Int: Int64] = [:]
            for index in ranges.indices { map[index] = 0 }
            received[id] = map
            partFiles[id] = [:]
            lock.unlock()

            update(id: id) { task in
                task.state = "下载中（\(ranges.count) 线程）"
                task.total = size
            }

            for (index, range) in ranges.enumerated() {
                var request = URLRequest(url: link.url)
                for (key, value) in link.headers { request.setValue(value, forHTTPHeaderField: key) }
                request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
                let downloadTask = session.downloadTask(with: request)
                lock.lock()
                refs[downloadTask.taskIdentifier] = PartRef(id: id, index: index)
                lock.unlock()
                downloadTask.resume()
            }
        } else {
            var request = URLRequest(url: link.url)
            for (key, value) in link.headers { request.setValue(value, forHTTPHeaderField: key) }
            let downloadTask = session.downloadTask(with: request)
            lock.lock()
            refs[downloadTask.taskIdentifier] = PartRef(id: id, index: 0)
            partRanges[id] = [0...(max(size, 1) - 1)]
            received[id] = [0: 0]
            partFiles[id] = [:]
            lock.unlock()
            update(id: id) { task in
                task.state = "下载中"
                task.total = size
            }
            downloadTask.resume()
        }
    }

    private func probe(link: DirectLink) async -> (size: Int64, ranged: Bool) {
        var head = URLRequest(url: link.url)
        head.httpMethod = "HEAD"
        for (key, value) in link.headers { head.setValue(value, forHTTPHeaderField: key) }
        if let (_, response) = try? await URLSession.shared.data(for: head),
           let http = response as? HTTPURLResponse, http.statusCode < 400 {
            let length = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0
            let ranged = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased().contains("bytes")
            if length > 0 { return (length, ranged) }
        }

        var rangedRequest = URLRequest(url: link.url)
        for (key, value) in link.headers { rangedRequest.setValue(value, forHTTPHeaderField: key) }
        rangedRequest.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        if let (_, response) = try? await URLSession.shared.data(for: rangedRequest),
           let http = response as? HTTPURLResponse {
            if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
               let totalText = contentRange.split(separator: "/").last,
               let total = Int64(totalText) {
                return (total, true)
            }
            let length = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0
            if length > 0 { return (length, false) }
        }
        return (0, false)
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let ref = reference(downloadTask.taskIdentifier) else { return }
        let done: Int64
        let total: Int64
        lock.lock()
        var map = received[ref.id] ?? [:]
        map[ref.index] = totalBytesWritten
        received[ref.id] = map
        done = map.values.reduce(0, +)
        total = totals[ref.id] ?? 0
        lock.unlock()

        var speedText = ""
        if let last = lastSpeed[ref.id] {
            let dt = Date().timeIntervalSince(last.time)
            if dt >= 1.0 {
                let delta = done - last.bytes
                speedText = ByteCountFormatter.string(fromByteCount: Int64(Double(delta) / dt), countStyle: .file) + "/s"
                lastSpeed[ref.id] = (Date(), done)
            }
        } else {
            lastSpeed[ref.id] = (Date(), done)
        }

        update(id: ref.id) { task in
            if total > 0 { task.progress = min(max(Double(done) / Double(total), 0), 0.995) }
            task.total = total
            if !speedText.isEmpty { task.speed = speedText }
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let key = downloadTask.taskIdentifier
        guard let ref = reference(key) else { return }

        lock.lock()
        let dir = started[ref.id]?.dir ?? FileManager.default.temporaryDirectory
        let partURL = dir.appendingPathComponent("part-\(ref.index)")
        lock.unlock()

        do {
            if FileManager.default.fileExists(atPath: partURL.path) {
                try FileManager.default.removeItem(at: partURL)
            }
            try FileManager.default.moveItem(at: location, to: partURL)
            lock.lock()
            var files = partFiles[ref.id] ?? [:]
            files[ref.index] = partURL
            partFiles[ref.id] = files
            let finished = files.count
            let expected = partRanges[ref.id]?.count ?? 1
            lock.unlock()
            forget(key)

            if finished >= expected {
                merge(id: ref.id)
            }
        } catch {
            fail(id: ref.id, message: "保存分片失败：\(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error, let ref = reference(task.taskIdentifier) else {
            forget(task.taskIdentifier)
            return
        }
        fail(id: ref.id, message: error.localizedDescription)
        forget(task.taskIdentifier)
    }

    // MARK: - 合并

    private func merge(id: UUID) {
        lock.lock()
        guard let info = started[id], let files = partFiles[id] else {
            lock.unlock()
            return
        }
        let ranges = partRanges[id] ?? []
        lock.unlock()

        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let target = docs.appendingPathComponent(info.name)
            try? fm.removeItem(at: target)
            fm.createFile(atPath: target.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: target) else {
                self.fail(id: id, message: "无法创建文件")
                return
            }
            do {
                for index in 0..<max(ranges.count, files.count) {
                    guard let part = files[index], fm.fileExists(atPath: part.path) else { continue }
                    let input = try FileHandle(forReadingFrom: part)
                    while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                        try handle.write(contentsOf: chunk)
                    }
                    try input.close()
                }
                try handle.close()
                try? fm.removeItem(at: info.dir)
                let attributes = try? fm.attributesOfItem(atPath: target.path)
                let finalSize = (attributes?[.size] as? Int64) ?? 0
                DispatchQueue.main.async {
                    if let index = self.tasks.firstIndex(where: { $0.id == id }) {
                        self.tasks[index].progress = 1
                        self.tasks[index].state = "已完成"
                        self.tasks[index].fileURL = target
                        self.tasks[index].total = finalSize
                        self.tasks[index].speed = ""
                    }
                    self.releaseIfIdle()
                }
            } catch {
                self.fail(id: id, message: "合并文件失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 工具

    private func reference(_ key: Int) -> PartRef? {
        lock.lock(); defer { lock.unlock() }
        return refs[key]
    }

    private func forget(_ key: Int) {
        lock.lock(); refs.removeValue(forKey: key); lock.unlock()
    }

    private func update(id: UUID, _ change: @escaping (inout DlTask) -> Void) {
        DispatchQueue.main.async {
            if let index = self.tasks.firstIndex(where: { $0.id == id }) {
                change(&self.tasks[index])
            }
        }
    }

    private func fail(id: UUID, message: String) {
        DispatchQueue.main.async {
            if let index = self.tasks.firstIndex(where: { $0.id == id }) {
                self.tasks[index].state = "失败"
                self.tasks[index].error = message
            }
            self.releaseIfIdle()
        }
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
        let running = tasks.contains { $0.state.contains("下载") || $0.state == "准备中" }
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
