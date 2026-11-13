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
    var paused: Bool = false
}

/// 多连接分片下载，支持暂停 / 继续 / 删除。
/// 每段落到临时分片文件，暂停后保留分片，继续时按已下载字节续传，全部完成再合并。
final class Downloader: NSObject, ObservableObject, URLSessionDownloadDelegate {

    static let shared = Downloader()

    var connections: Int = 6

    @Published private(set) var tasks: [DlTask] = []

    private struct PartPlan {
        let range: ClosedRange<Int64>
        let file: URL
        var have: Int64 = 0
    }

    private struct Meta {
        let name: String
        let dir: URL
        let total: Int64
        let url: URL
        let headers: [String: String]
    }

    private var plans: [UUID: [PartPlan]] = [:]
    private var metas: [UUID: Meta] = [:]
    private var taskMap: [Int: (id: UUID, index: Int)] = [:]
    private var runningTasks: [Int: URLSessionTask] = [:]
    private var written: [UUID: [Int: Int64]] = [:]
    private var pausedIDs = Set<UUID>()
    private var lastTick: [UUID: (Date, Int64)] = [:]
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
        Task { await prepare(id: id, name: safe, link: link) }
    }

    func pause(_ task: DlTask) {
        pause(id: task.id)
    }

    func resume(_ task: DlTask) {
        lock.lock()
        pausedIDs.remove(task.id)
        lock.unlock()
        update(id: task.id) { item in
            item.state = "下载中"
            item.paused = false
            item.error = nil
        }
        launch(id: task.id)
        keepAlive()
    }

    func remove(_ task: DlTask) {
        pause(id: task.id)
        lock.lock()
        let meta = metas[task.id]
        let parts = plans[task.id] ?? []
        plans.removeValue(forKey: task.id)
        metas.removeValue(forKey: task.id)
        written.removeValue(forKey: task.id)
        lock.unlock()
        if let meta {
            try? FileManager.default.removeItem(at: meta.dir)
        }
        for part in parts { try? FileManager.default.removeItem(at: part.file) }
        if let url = task.fileURL { try? FileManager.default.removeItem(at: url) }
        DispatchQueue.main.async {
            self.tasks.removeAll { $0.id == task.id }
            self.releaseIfIdle()
        }
    }

    func clearFinished() {
        tasks.removeAll { $0.state == "已完成" || $0.state == "失败" }
    }

    private func pause(id: UUID) {
        lock.lock()
        pausedIDs.insert(id)
        let ids = taskMap.filter { $0.value.id == id }.map { $0.key }
        let running = ids.compactMap { runningTasks[$0] }
        lock.unlock()
        for task in running {
            task.cancel()
        }
        update(id: id) { item in
            if item.state != "已完成" { item.state = "已暂停"; item.paused = true }
            item.speed = ""
        }
        releaseIfIdle()
    }

    // MARK: - 准备

    private func prepare(id: UUID, name: String, link: DirectLink) async {
        let probe = await probe(link: link)
        let size = probe.size
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(id.uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var ranges: [ClosedRange<Int64>]
        if probe.ranged && size > 2 * 1024 * 1024 {
            let count = max(2, min(connections, 8))
            let chunk = size / Int64(count)
            ranges = []
            var start: Int64 = 0
            for index in 0..<count {
                let end = index == count - 1 ? size - 1 : start + chunk - 1
                ranges.append(start...end)
                start = end + 1
            }
        } else {
            ranges = [0...(max(size, 1) - 1)]
        }

        lock.lock()
        metas[id] = Meta(name: name, dir: dir, total: size, url: link.url, headers: link.headers)
        plans[id] = ranges.enumerated().map { index, range in
            PartPlan(range: range, file: dir.appendingPathComponent("part-\(index)"))
        }
        written[id] = [:]
        lock.unlock()

        update(id: id) { item in
            item.state = ranges.count > 1 ? "下载中（\(ranges.count) 线程）" : "下载中"
            item.total = size
            item.paused = false
        }
        launch(id: id)
    }

    private func launch(id: UUID) {
        lock.lock()
        guard let parts = plans[id], let meta = metas[id] else {
            lock.unlock()
            return
        }
        var started = 0
        for (index, part) in parts.enumerated() {
            let length = part.range.upperBound - part.range.lowerBound + 1
            guard part.have < length else { continue }
            let start = part.range.lowerBound + part.have
            var request = URLRequest(url: meta.url)
            for (key, value) in meta.headers { request.setValue(value, forHTTPHeaderField: key) }
            if meta.total > 0 {
                request.setValue("bytes=\(start)-\(part.range.upperBound)", forHTTPHeaderField: "Range")
            }
            let downloadTask = session.downloadTask(with: request)
            taskMap[downloadTask.taskIdentifier] = (id, index)
            runningTasks[downloadTask.taskIdentifier] = downloadTask
            started += 1
            downloadTask.resume()
        }
        lock.unlock()

        if started == 0 { mergeIfComplete(id: id) }
    }

    // MARK: - 探测

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
        lock.lock()
        guard let ref = taskMap[downloadTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        var map = written[ref.id] ?? [:]
        map[ref.index] = totalBytesWritten
        written[ref.id] = map

        let parts = plans[ref.id] ?? []
        let haveSum = parts.reduce(Int64(0)) { $0 + $1.have }
        let writtenSum = map.values.reduce(Int64(0), +)
        let total = metas[ref.id]?.total ?? 0
        lock.unlock()

        var speedText = ""
        let now = Date()
        if let last = lastTick[ref.id] {
            let dt = now.timeIntervalSince(last.0)
            if dt >= 1.0 {
                let delta = haveSum + writtenSum - last.1
                speedText = ByteCountFormatter.string(fromByteCount: Int64(Double(delta) / dt), countStyle: .file) + "/s"
                lastTick[ref.id] = (now, haveSum + writtenSum)
            }
        } else {
            lastTick[ref.id] = (now, haveSum + writtenSum)
        }

        update(id: ref.id) { item in
            if total > 0 {
                item.progress = min(max(Double(haveSum + writtenSum) / Double(total), 0), 0.995)
            }
            if !speedText.isEmpty { item.speed = speedText }
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let key = downloadTask.taskIdentifier
        lock.lock()
        guard let ref = taskMap[key], var parts = plans[ref.id], ref.index < parts.count else {
            taskMap.removeValue(forKey: key)
            runningTasks.removeValue(forKey: key)
            lock.unlock()
            return
        }
        let part = parts[ref.index]
        let dir = metas[ref.id]?.dir ?? FileManager.default.temporaryDirectory
        let incoming = dir.appendingPathComponent("incoming-\(ref.index)-\(UUID().uuidString)")
        taskMap.removeValue(forKey: key)
        runningTasks.removeValue(forKey: key)
        lock.unlock()

        do {
            try FileManager.default.moveItem(at: location, to: incoming)
            if FileManager.default.fileExists(atPath: part.file.path) {
                // 续传：把新片段追加到已有分片后面
                let handle = try FileHandle(forWritingTo: part.file)
                handle.seekToEndOfFile()
                let input = try FileHandle(forReadingFrom: incoming)
                while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                    handle.write(chunk)
                }
                try input.close()
                try handle.close()
                try FileManager.default.removeItem(at: incoming)
            } else {
                try FileManager.default.moveItem(at: incoming, to: part.file)
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: part.file.path)
            let size = (attributes?[.size] as? Int64) ?? 0
            lock.lock()
            parts[ref.index].have = size
            plans[ref.id] = parts
            var map = written[ref.id] ?? [:]
            map.removeValue(forKey: ref.index)
            written[ref.id] = map
            lock.unlock()
            mergeIfComplete(id: ref.id)
        } catch {
            fail(id: ref.id, message: "保存分片失败：\(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let key = task.taskIdentifier
        guard let error = error else {
            lock.lock()
            taskMap.removeValue(forKey: key)
            runningTasks.removeValue(forKey: key)
            lock.unlock()
            return
        }
        lock.lock()
        let ref = taskMap[key]
        let paused = ref.map { pausedIDs.contains($0.id) } ?? false
        taskMap.removeValue(forKey: key)
        runningTasks.removeValue(forKey: key)
        lock.unlock()
        if !paused, let ref {
            fail(id: ref.id, message: error.localizedDescription)
        }
    }

    // MARK: - 合并

    private func mergeIfComplete(id: UUID) {
        lock.lock()
        guard let meta = metas[id], let parts = plans[id] else {
            lock.unlock()
            return
        }
        let complete = parts.allSatisfy { part -> Bool in
            let attributes = try? FileManager.default.attributesOfItem(atPath: part.file.path)
            let size = (attributes?[.size] as? Int64) ?? 0
            if meta.total <= 0 { return size > 0 }
            let length = part.range.upperBound - part.range.lowerBound + 1
            return size >= length
        }
        guard complete else {
            lock.unlock()
            return
        }
        lock.unlock()

        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let target = docs.appendingPathComponent(meta.name)
            try? fm.removeItem(at: target)
            fm.createFile(atPath: target.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: target) else {
                self.fail(id: id, message: "无法创建文件")
                return
            }
            do {
                for part in parts {
                    let input = try FileHandle(forReadingFrom: part.file)
                    while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                        try handle.write(contentsOf: chunk)
                    }
                    try input.close()
                }
                try handle.close()
                try? fm.removeItem(at: meta.dir)
                let attributes = try? fm.attributesOfItem(atPath: target.path)
                let finalSize = (attributes?[.size] as? Int64) ?? 0
                self.lock.lock()
                self.plans.removeValue(forKey: id)
                self.metas.removeValue(forKey: id)
                self.written.removeValue(forKey: id)
                self.lock.unlock()
                DispatchQueue.main.async {
                    if let index = self.tasks.firstIndex(where: { $0.id == id }) {
                        self.tasks[index].progress = 1
                        self.tasks[index].state = "已完成"
                        self.tasks[index].fileURL = target
                        self.tasks[index].total = finalSize
                        self.tasks[index].speed = ""
                        self.tasks[index].paused = false
                    }
                    self.releaseIfIdle()
                }
            } catch {
                self.fail(id: id, message: "合并文件失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 工具

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
                self.tasks[index].speed = ""
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
