import Foundation

/// 应用私有的页面资源仓库；不持久化商品、资格或 WebView 会话。
public actor WebPaywallResourceCache {
    public static let shared = WebPaywallResourceCache()
    private let root: URL
    private let capacity: Int
    private let downloadTimeout: TimeInterval
    private let fetch: @Sendable (URL, Int, Date) async throws -> Data
    private var pending: [String: Task<URL, Error>] = [:]
    private var pendingIDs: [String: UUID] = [:]
    private var leases: [String: Int] = [:]
    private var pins: [String: Int] = [:]
    private var downloads = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(directory: URL? = nil, capacityBytes: Int = 300 * 1024 * 1024, downloadTimeout: TimeInterval = 6) {
        root = (directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaywallKit/PagePackages", isDirectory: true)).resolvingSymlinksInPath()
        capacity = max(0, capacityBytes)
        self.downloadTimeout = downloadTimeout
        fetch = { url, limit, deadline in
            try await WebPaywallResourceDownload().fetch(url, limit: limit, deadline: deadline)
        }
    }

    /// 允许宿主侧测试注入传输，实际页面仍走同一清单与磁盘校验。
    init(directory: URL, capacityBytes: Int = 300 * 1024 * 1024,
         fetch: @escaping @Sendable (URL, Int, Date) async throws -> Data) {
        root = directory.resolvingSymlinksInPath()
        capacity = max(0, capacityBytes)
        downloadTimeout = 6
        self.fetch = fetch
    }

    /// 命中直接读取磁盘；后台可提供较长下载期限，同版本仍共用首个下载任务。
    public func prepare(document: WebPaywallDocument, runtimeEnvironment: String,
                        downloadTimeout: TimeInterval? = nil) async throws -> WebPaywallResourceLease {
        guard ["test", "production"].contains(runtimeEnvironment), document.localReadAccessURL == nil else {
            throw WebPaywallError.invalidDocument
        }
        let identity = try WebPaywallPackage.identity(document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let key = WebPaywallPackage.digest(try encoder.encode(identity) + Data(runtimeEnvironment.utf8))
        // 等待任务也先占用租约，避免下载完成与挂载之间被清理。
        WebPaywallDiagnostics.log(runtimeEnvironment, "resource.prepare", "key=\(key) shared=\(pending[key] != nil)")
        pins[key, default: 0] += 1
        if pending[key] == nil {
            pendingIDs[key] = UUID()
            let timeout = downloadTimeout.map { min(120, max(1, $0)) } ?? self.downloadTimeout
            pending[key] = Task { try await self.resolve(key, identity, runtimeEnvironment, timeout: timeout) }
        }
        let token = pendingIDs[key]
        defer {
            if pendingIDs[key] == token {
                pending[key] = nil
                pendingIDs[key] = nil
            }
        }
        do {
            let directory = try await pending[key]!.value
            try Task.checkCancellation()
            leases[key, default: 0] += 1
            WebPaywallDiagnostics.log(runtimeEnvironment, "resource.lease", "key=\(key) count=\(leases[key] ?? 0)")
            return WebPaywallResourceLease(directory: directory) { Task { await self.release(key, runtimeEnvironment) } }
        } catch {
            WebPaywallDiagnostics.log(runtimeEnvironment, "resource.failed", "key=\(key) code=\((error as NSError).code)")
            unpin(key)
            throw error
        }
    }

    /// 成功版本归档只读取已完整下载的资源，不因首屏成功再发起网络下载。
    func cachedPackage(document: WebPaywallDocument, environment: String) throws -> WebPaywallResourceLease {
        let identity = try WebPaywallPackage.identity(document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let key = WebPaywallPackage.digest(try encoder.encode(identity) + Data(environment.utf8))
        let directory = root.appendingPathComponent(key, isDirectory: true)
        try verify(directory, identity, environment)
        pins[key, default: 0] += 1
        leases[key, default: 0] += 1
        return WebPaywallResourceLease(directory: directory) { Task { await self.release(key, environment) } }
    }

    /// 手动清理只删除空闲包；活跃会话与在途下载不受影响。
    public func clear() { prune(limit: 0) }

    /// 释放最后一个使用者后按容量淘汰旧版本。
    private func release(_ key: String, _ environment: String) {
        WebPaywallDiagnostics.log(environment, "resource.release", "key=\(key)")
        leases[key] = max(0, (leases[key] ?? 1) - 1)
        unpin(key)
    }

    /// 失败等待者只归还预留，不影响其他已经挂载的租约。
    private func unpin(_ key: String) {
        pins[key] = max(0, (pins[key] ?? 1) - 1)
        prune(limit: capacity)
    }

    /// 私有目录排除备份；启动时清理由上次进程中断留下的临时包。
    private func prepareRoot() throws {
        let fm = FileManager.default
        let existed = fm.fileExists(atPath: root.path)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard root.resolvingSymlinksInPath().standardizedFileURL == root.standardizedFileURL else {
            throw WebPaywallError.invalidDocument
        }
        var location = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try location.setResourceValues(values)
        if !existed { return }
        // 本进程在途目录不扫描删除；过期临时目录在没有下载时清理。
        if downloads == 0 {
            for url in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                where url.lastPathComponent.hasPrefix("tmp-") {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// 完整校验磁盘后才复用，损坏包绝不作为降级页面。
    private func resolve(_ key: String, _ identity: WebPaywallPackage.Document, _ environment: String,
                         timeout: TimeInterval) async throws -> URL {
        try prepareRoot()
        let directory = root.appendingPathComponent(key, isDirectory: true)
        if (try? verify(directory, identity, environment)) != nil {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
            WebPaywallDiagnostics.log(environment, "resource.hit", "key=\(key)")
            return directory
        }
        WebPaywallDiagnostics.log(environment, "resource.miss", "key=\(key)")
        if FileManager.default.fileExists(atPath: directory.path) {
            WebPaywallDiagnostics.log(environment, "resource.invalid", "key=\(key)")
            guard (leases[key] ?? 0) == 0 else { throw WebPaywallError.invalidDocument }
            try FileManager.default.removeItem(at: directory)
        }
        WebPaywallDiagnostics.log(environment, "resource.download_wait", "key=\(key) active=\(downloads)")
        await acquireDownload()
        defer { finishDownload() }
        return try await download(directory, identity, environment, timeout: timeout)
    }

    /// 最多两个页面同时下载，排队不会占用网络连接。
    private func acquireDownload() async {
        if downloads >= 2 {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            downloads += 1
        }
    }

    /// 唤醒一个排队页面并交还下载槽位。
    private func finishDownload() {
        if !waiters.isEmpty { waiters.removeFirst().resume() }
        else { downloads -= 1 }
    }

    /// 下载到临时目录，全部校验通过后一次性启用。
    private func download(_ destination: URL, _ identity: WebPaywallPackage.Document, _ environment: String,
                          timeout: TimeInterval) async throws -> URL {
        WebPaywallDiagnostics.log(environment, "resource.download_start", "key=\(destination.lastPathComponent)")
        let fm = FileManager.default
        let temporary = root.appendingPathComponent("tmp-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let base = URL(string: identity.pageUrl)!.deletingLastPathComponent()
        let deadline = Date().addingTimeInterval(timeout)
        let data = try await fetch(base.appendingPathComponent("package.json"), 256_000, deadline)
        let package = try WebPaywallPackage.parse(data, identity: identity, environment: environment)
        // 逐文件验证，不允许部分成功的包进入正式目录。
        for file in package.files {
            let bytes = try await fetch(base.appendingPathComponent(file.path), file.size, deadline)
            guard bytes.count == file.size, WebPaywallPackage.digest(bytes) == file.sha256 else {
                throw WebPaywallError.invalidDocument
            }
            let target = temporary.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target)
        }
        try data.write(to: temporary.appendingPathComponent("package.json"))
        try fm.moveItem(at: temporary, to: destination)
        WebPaywallDiagnostics.log(environment, "resource.download_ready", "key=\(destination.lastPathComponent) files=\(package.files.count)")
        prune(limit: capacity)
        return destination
    }

    /// 每次命中检查完整文件集，拒绝链接逃逸和磁盘损坏。
    private func verify(_ directory: URL, _ identity: WebPaywallPackage.Document, _ environment: String) throws {
        try WebPaywallPackage.verify(directory, identity: identity, environment: environment)
    }

    /// 按最近使用顺序淘汰空闲包，所有活跃包超过容量时延迟清理。
    private func prune(limit: Int) {
        let fm = FileManager.default
        guard let directories = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let packages = directories.filter { $0.lastPathComponent.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
        let sorted = packages.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) <
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        let sizes = sorted.map { directory -> Int in
            guard let files = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
            return files.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }.reduce(0, +)
        }
        var total = sizes.reduce(0, +)
        for (directory, size) in zip(sorted, sizes) where total > limit && (pins[directory.lastPathComponent] ?? 0) == 0 {
            let manifest = try? Data(contentsOf: directory.appendingPathComponent("package.json"))
            let metadata = manifest.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if (try? fm.removeItem(at: directory)) != nil {
                WebPaywallDiagnostics.log(metadata?["runtimeEnvironment"] as? String ?? "", "resource.evicted",
                    "key=\(directory.lastPathComponent) bytes=\(size) limit=\(limit)")
                total -= size
            }
        }
    }
}
