import Foundation

/// SDK 私有滚动日志；有界内存缓冲和串行磁盘队列不阻塞加载路径。
final class PaywallLogStore: @unchecked Sendable {
    private let root: URL
    private let fileBytes: Int
    private let bufferBytes: Int
    private let queue = DispatchQueue(label: "PaywallKit.LogStore", qos: .utility)
    private let lock = NSLock()
    private var pending: [String] = []
    private var pendingBytes = 0
    private var dropped = 0
    private var scheduled = false
    private var storageFailed = false

    init(directory: URL? = nil, fileBytes: Int = 1024 * 1024, bufferBytes: Int = 128 * 1024) {
        root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaywallKit/Diagnostics", isDirectory: true)
        self.fileBytes = fileBytes
        self.bufferBytes = bufferBytes
    }

    /// 同步仅入队少量文本；后台合并批量写入，失败不会传播给支付墙。
    func append(_ line: String) {
        let clipped = String(line.prefix(2048)) + (line.count > 2048 ? " [truncated]" : "") + "\n"
        lock.lock()
        add(clipped)
        let start = !scheduled
        scheduled = true
        lock.unlock()
        if start { schedule() }
    }

    /// 队列始终至多保留一个批次任务，防止高频日志积累无界闭包。
    private func schedule() {
        queue.async { [self] in
            let success = flush()
            lock.lock()
            let again = success && (!pending.isEmpty || dropped > 0)
            scheduled = again
            lock.unlock()
            if again { schedule() }
        }
    }

    /// 仅在持锁时修改缓冲；超限丢弃最旧记录并保留丢弃计数。
    private func add(_ line: String) {
        pending.append(line)
        pendingBytes += line.utf8.count
        while pendingBytes > bufferBytes && !pending.isEmpty {
            pendingBytes -= pending.removeFirst().utf8.count
            dropped += 1
        }
    }

    /// 从缓冲取出一次快照，写失败时将未确认数据放回有界缓冲。
    @discardableResult private func flush() -> Bool {
        lock.lock()
        var lines = pending
        if dropped > 0 { lines.insert("[PaywallKit] logs.dropped count=\(dropped)\n", at: 0) }
        pending = []; pendingBytes = 0; dropped = 0
        lock.unlock()
        guard !lines.isEmpty else { return true }
        do {
            try prepareRoot()
            try write(lines)
            storageFailed = false
            return true
        } catch {
            storageFailed = true
            lock.lock()
            let newer = pending
            pending = []; pendingBytes = 0
            for line in lines + newer { add(line) }
            lock.unlock()
            return false
        }
    }

    /// 私有目录排除备份，日志文件不参与资源缓存的清理策略。
    private func prepareRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var location = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try location.setResourceValues(values)
    }

    /// 按容量分批追加，避免每条事件打开一次文件；最多三个滚动文件。
    private func write(_ lines: [String]) throws {
        let current = file(0)
        var size = (try? current.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var chunk = Data()
        for original in lines {
            let line = original.utf8.count <= fileBytes ? original : "[PaywallKit] logs.line_too_large\n"
            let data = Data(line.utf8)
            if size + data.count > fileBytes {
                try appendBytes(chunk, to: current)
                try rotate()
                chunk = Data(); size = 0
            }
            chunk.append(data); size += data.count
        }
        try appendBytes(chunk, to: current)
    }

    /// 追加完成即关闭文件；读取和导出排在同一磁盘队列后面。
    private func appendBytes(_ bytes: Data, to url: URL) throws {
        guard !bytes.isEmpty else { return }
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
    }

    /// 固定名称轮转不触碰其他文件，保留最近两个历史片段。
    private func rotate() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: file(2).path) { try fm.removeItem(at: file(2)) }
        for index in stride(from: 1, through: 0, by: -1) where fm.fileExists(atPath: file(index).path) {
            try fm.moveItem(at: file(index), to: file(index + 1))
        }
    }

    private func file(_ index: Int) -> URL { root.appendingPathComponent("paywall-\(index).log") }

    /// 等待已有写入再读取；磁盘不可用时返回内存记录及不可用标记。
    func read() async -> String {
        await withCheckedContinuation { continuation in
            queue.async { [self] in flush(); continuation.resume(returning: snapshot()) }
        }
    }

    /// 输出由旧到新排列；单文件损坏不会吞掉其他日志。
    private func snapshot() -> String {
        var result = ""
        if storageFailed || !FileManager.default.fileExists(atPath: root.path) {
            result += "[PaywallKit] logs.storage_unavailable source=memory\n"
        }
        for index in stride(from: 2, through: 0, by: -1) where FileManager.default.fileExists(atPath: file(index).path) {
            if let data = try? Data(contentsOf: file(index)) { result += String(decoding: data, as: UTF8.self) }
            else { result += "[PaywallKit] logs.read_failed file=\(index)\n" }
        }
        lock.lock()
        if dropped > 0 { result += "[PaywallKit] logs.dropped count=\(dropped)\n" }
        result += pending.joined()
        lock.unlock()
        return result
    }

    /// 生成可分享的固定快照，重复导出覆盖同一文件，不自动上传。
    func export() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    flush()
                    try prepareRoot()
                    let target = root.appendingPathComponent("paywall-export.log")
                    try Data(snapshot().utf8).write(to: target, options: .atomic)
                    continuation.resume(returning: target)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// 清除现有文件与缓冲，之后的新事件继续自动记录。
    func clear() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                lock.lock(); pending = []; pendingBytes = 0; dropped = 0; lock.unlock()
                do {
                    let files = (0...2).map(file) + [root.appendingPathComponent("paywall-export.log")]
                    for url in files where FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
