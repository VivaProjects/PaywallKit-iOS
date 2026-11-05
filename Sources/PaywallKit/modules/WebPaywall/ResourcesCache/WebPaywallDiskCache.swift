import Foundation

/// 可重新下载的页面包共用容量和闲置期限；兜底更新仓库独立保留。
final class WebPaywallDiskCache: @unchecked Sendable {
    static let shared = WebPaywallDiskCache()
    static let capacityBytes = 300 * 1024 * 1024
    static let maxIdleTime: TimeInterval = 30 * 24 * 60 * 60

    private struct Entry {
        let directory: URL
        let size: Int
        let date: Date
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "PaywallKit.disk-cache", qos: .utility)
    private var roots: [String: Bool] = [:]
    private var users: [String: Int] = [:]
    private var scheduled = false
    private var requested = false

    /// 固定扫描 SDK 的三个缓存域，旧请求作用域也参与总量统计。
    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaywallKit")
        roots[base.appendingPathComponent("PagePackages").standardizedFileURL.path] = false
        roots[base.appendingPathComponent("QuerySnapshots").standardizedFileURL.path] = true
        roots[base.appendingPathComponent("SuccessfulVersions").standardizedFileURL.path] = true
    }

    /// 自定义资源仓库沿用统一预算；分组目录只向下一层查找包。
    func register(_ directory: URL, grouped: Bool = false) {
        lock.lock()
        roots[directory.standardizedFileURL.path] = grouped
        lock.unlock()
        schedule()
    }

    /// 校验或写入前先预留目录，避免扫描与挂载之间出现删除窗口。
    func retain(_ directory: URL) {
        let key = directory.standardizedFileURL.path
        lock.lock()
        users[key, default: 0] += 1
        touch(directory)
        lock.unlock()
    }

    /// 归还时记录最后使用时间，长时间展示的页面从关闭时开始计算闲置。
    func release(_ directory: URL) {
        let key = directory.standardizedFileURL.path
        lock.lock()
        users[key] = max(0, (users[key] ?? 1) - 1)
        if users[key] == 0 { users[key] = nil }
        touch(directory)
        lock.unlock()
        schedule()
    }

    /// 合并启动、下载及释放事件；扫描期间的新请求由下一轮处理。
    func schedule() {
        lock.lock()
        requested = true
        let start = !scheduled
        scheduled = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    /// 递归扫描与删除仅在工具队列执行，主线程只登记目录租约。
    private func drain() {
        while true {
            lock.lock()
            guard requested else {
                scheduled = false
                lock.unlock()
                return
            }
            requested = false
            let locations = roots
            lock.unlock()
            prune(entries(locations))
        }
    }

    /// 只读取非符号链接的摘要包目录，忽略配置、日志和兜底资源。
    private func entries(_ locations: [String: Bool]) -> [Entry] {
        let fm = FileManager.default
        var packages = Set<URL>()
        for (path, grouped) in locations {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            guard root.resolvingSymlinksInPath().path == path else { continue }
            let parents = grouped ? children(root).filter(isDigestDirectory) : [root]
            for parent in parents {
                for directory in children(parent) where isDigestDirectory(directory) {
                    packages.insert(directory)
                }
                // 仅回收本维护器上次进程中断留下的隔离目录。
                for trash in children(parent) where trash.lastPathComponent.hasPrefix("evicted-") {
                    try? fm.removeItem(at: trash)
                }
            }
        }
        return packages.compactMap { directory in
            guard let date = lastUsed(directory) else { return nil }
            let size = packageSize(directory)
            return .init(directory: directory, size: size, date: date)
        }.sorted { $0.date < $1.date }
    }

    /// 统计物理包内全部文件，不跟随链接跳出缓存目录。
    private func packageSize(_ directory: URL) -> Int {
        let fm = FileManager.default
        guard let files = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) else { return 0 }
        var size = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { files.skipDescendants(); continue }
            size += values.fileSize ?? 0
        }
        return size
    }

    /// 先删过期包，再按最后使用时间压缩总量；租约保护可暂时超过预算。
    private func prune(_ entries: [Entry]) {
        var total = entries.reduce(0) { $0 + $1.size }
        let cutoff = Date().addingTimeInterval(-Self.maxIdleTime)
        for entry in entries where entry.date <= cutoff || total > Self.capacityBytes {
            // 扫描后可能重新使用，必须在同一把锁内检查时间、租约并隔离。
            guard let trash = quarantine(entry) else { continue }
            do {
                try FileManager.default.removeItem(at: trash)
                total -= entry.size
            } catch {
                // 保留隔离目录供下次重试，不影响已有会话。
            }
        }
    }

    /// 原子改名后只删除隔离目录，新请求可以安全地重新下载原路径。
    private func quarantine(_ entry: Entry) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        let directory = entry.directory.standardizedFileURL
        guard users[directory.path] == nil, isDigestDirectory(directory),
              let date = lastUsed(directory),
              date <= entry.date else { return nil }
        let trash = directory.deletingLastPathComponent().appendingPathComponent("evicted-" + UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: directory, to: trash)
            return trash
        } catch { return nil }
    }

    /// 淘汰前直接查询文件系统，不能复用 URL 缓存的旧时间属性。
    private func lastUsed(_ directory: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: directory.path)[.modificationDate]) as? Date
    }

    /// 最后使用时间仅改目录属性，不修改清单、资源摘要或业务有效期。
    private func touch(_ directory: URL) {
        guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else { return }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
    }

    /// 目录枚举失败视为无候选，后续缓存事件会重试。
    private func children(_ directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    }

    /// 只接收真实摘要目录，禁止符号链接逃逸和删除非包文件。
    private func isDigestDirectory(_ directory: URL) -> Bool {
        directory.lastPathComponent.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
            && directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path
            && (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
