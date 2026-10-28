import Foundation

/// 应用私有的页面资源仓库；不持久化商品、资格或 WebView 会话。
public actor WebPaywallResourceCache {
    public static let shared = WebPaywallResourceCache()
    private let root: URL
    private let capacity: Int
    private let downloadTimeout: TimeInterval
    private let fetch: (@Sendable (URL, Int, Date) async throws -> Data)?
    private var rootTask: (id: UUID, task: Task<Void, Error>)?
    private var verifications: [String: (id: UUID, task: Task<Void, Error>)] = [:]
    private let beforeVerify: (@Sendable (URL) async -> Void)?
    private let cleanup: @Sendable (URL) async -> String?
    private var pending: [String: Task<URL, Error>] = [:]
    private var pendingIDs: [String: UUID] = [:]
    private var leases: [String: Int] = [:]
    private var pins: [String: Int] = [:]
    private let scan: (@Sendable (URL) async -> [WebPaywallCacheMaintenance.Entry])?
    private var pruning: Task<Void, Never>?
    private var pendingPruneLimit: Int?
    private var downloads = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(directory: URL? = nil, capacityBytes: Int = 300 * 1024 * 1024, downloadTimeout: TimeInterval = 6) {
        root = (directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaywallKit/PagePackages", isDirectory: true)).resolvingSymlinksInPath()
        capacity = max(0, capacityBytes)
        self.downloadTimeout = downloadTimeout
        fetch = nil
        scan = nil
        beforeVerify = nil
        cleanup = { await WebPaywallCacheMaintenance.remove($0) }
    }

    /// 允许宿主侧测试注入传输，实际页面仍走同一清单与磁盘校验。
    init(directory: URL, capacityBytes: Int = 300 * 1024 * 1024,
         scan: (@Sendable (URL) async -> [WebPaywallCacheMaintenance.Entry])? = nil,
         beforeVerify: (@Sendable (URL) async -> Void)? = nil,
         cleanup: @escaping @Sendable (URL) async -> String? = { await WebPaywallCacheMaintenance.remove($0) },
         fetch: @escaping @Sendable (URL, Int, Date) async throws -> Data) {
        root = directory.resolvingSymlinksInPath()
        capacity = max(0, capacityBytes)
        downloadTimeout = 6
        self.fetch = fetch
        self.scan = scan
        self.beforeVerify = beforeVerify
        self.cleanup = cleanup
    }

    /// 命中直接读取磁盘；后台可提供较长下载期限，同版本仍共用首个下载任务。
    public func prepare(document: WebPaywallDocument, runtimeEnvironment: String,
                        downloadTimeout: TimeInterval? = nil, manifestData: Data? = nil) async throws -> WebPaywallResourceLease {
        guard ["test", "production"].contains(runtimeEnvironment), document.localReadAccessURL == nil else {
            throw WebPaywallError.invalidDocument
        }
        let identity = try WebPaywallPackage.identity(document)
        // 复用清单仍完整校验，错误环境或身份不能因已有磁盘缓存而通过。
        if let manifestData { _ = try WebPaywallPackage.parse(manifestData, identity: identity, environment: runtimeEnvironment) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let key = WebPaywallPackage.digest(try encoder.encode(identity) + Data(runtimeEnvironment.utf8))
        // 等待任务也先占用租约，避免下载完成与挂载之间被清理。
        WebPaywallDiagnostics.log(runtimeEnvironment, "resource.prepare", "key=\(key) shared=\(pending[key] != nil)")
        pins[key, default: 0] += 1
        if pending[key] == nil {
            pendingIDs[key] = UUID()
            let timeout = downloadTimeout.map { min(120, max(1, $0)) } ?? self.downloadTimeout
            pending[key] = Task { try await self.resolve(key, identity, runtimeEnvironment, timeout: timeout, manifestData: manifestData) }
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

    /// 同次更新直接交接刚验证的目录，后续重新打开仍走完整资源验证。
    func prepareLocal(document: WebPaywallDocument, environment: String) async throws
        -> (WebPaywallDocument, WebPaywallResourceLease) {
        let lease = try await prepare(document: document, runtimeEnvironment: environment)
        try Task.checkCancellation()
        return (try document.usingPreparedResources(lease), lease)
    }

    /// 成功版本归档只读取已完整下载的资源，不因首屏成功再发起网络下载。
    func cachedPackage(document: WebPaywallDocument, environment: String) async throws -> WebPaywallResourceLease {
        let identity = try WebPaywallPackage.identity(document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let key = WebPaywallPackage.digest(try encoder.encode(identity) + Data(environment.utf8))
        let directory = root.appendingPathComponent(key, isDirectory: true)
        try Task.checkCancellation()
        pins[key, default: 0] += 1
        do {
            try await prepareRoot()
            try await verify(directory, key: key, identity: identity, environment: environment)
            try Task.checkCancellation()
            leases[key, default: 0] += 1
            return WebPaywallResourceLease(directory: directory) { Task { await self.release(key, environment) } }
        } catch {
            unpin(key)
            throw error
        }
    }

    /// 本地仓库在校验前预留目录，结果持有租约直到展示结束。
    func validatedLocal(directoryName: String, identity: WebPaywallPackage.Document,
                        environment: String, catalog: PaywallCatalog) async throws -> (WebPaywallDocument, WebPaywallResourceLease) {
        guard directoryName.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw WebPaywallError.invalidDocument
        }
        let directory = root.appendingPathComponent(directoryName)
        pins[directoryName, default: 0] += 1
        do {
            let document = try await WebPaywallLocalDocumentLoader.load(directory: directory,
                identity: identity, environment: environment, catalog: catalog)
            leases[directoryName, default: 0] += 1
            let lease = WebPaywallResourceLease(directory: directory) {
                Task { await self.release(directoryName, environment) }
            }
            return (document, lease)
        } catch {
            unpin(directoryName)
            throw error
        }
    }

    /// 手动清理只删除空闲包；活跃会话与在途下载不受影响。
    public func clear() async {
        schedulePrune(limit: 0)
        await pruning?.value
    }

    /// 释放最后一个使用者后按容量淘汰旧版本。
    private func release(_ key: String, _ environment: String) {
        WebPaywallDiagnostics.log(environment, "resource.release", "key=\(key)")
        leases[key] = max(0, (leases[key] ?? 1) - 1)
        unpin(key)
    }

    /// 失败等待者只归还预留，不影响其他已经挂载的租约。
    private func unpin(_ key: String) {
        pins[key] = max(0, (pins[key] ?? 1) - 1)
        schedulePrune(limit: capacity)
    }

    /// 根目录仅初始化一次，后台清理旧临时包时不会占用仓库执行器。
    private func prepareRoot() async throws {
        if rootTask == nil {
            let root = self.root
            rootTask = (UUID(), Task.detached(priority: .utility) {
                try Self.initializeRoot(root)
            })
        }
        let pending = rootTask!
        do {
            try await pending.task.value
            // 初始化可合并，但每次使用仍拒绝根目录被替换为链接或移除。
            guard FileManager.default.fileExists(atPath: root.path),
                  root.resolvingSymlinksInPath().standardizedFileURL == root.standardizedFileURL else {
                throw WebPaywallError.invalidDocument
            }
        } catch {
            if rootTask?.id == pending.id { rootTask = nil }
            throw error
        }
    }

    /// 所有下载都等待首次目录准备完成，因此不会清理本进程的在途临时包。
    private static func initializeRoot(_ root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard root.resolvingSymlinksInPath().standardizedFileURL == root.standardizedFileURL else {
            throw WebPaywallError.invalidDocument
        }
        var location = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try location.setResourceValues(values)
        for url in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix("tmp-") {
            try? fm.removeItem(at: url)
        }
    }

    /// 完整校验磁盘后才复用，损坏包绝不作为降级页面。
    private func resolve(_ key: String, _ identity: WebPaywallPackage.Document, _ environment: String,
                         timeout: TimeInterval, manifestData: Data?) async throws -> URL {
        try await prepareRoot()
        let directory = root.appendingPathComponent(key, isDirectory: true)
        if (try? await verify(directory, key: key, identity: identity, environment: environment)) != nil {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
            WebPaywallDiagnostics.log(environment, "resource.hit", "key=\(key)")
            return directory
        }
        WebPaywallDiagnostics.log(environment, "resource.miss", "key=\(key)")
        if FileManager.default.fileExists(atPath: directory.path) {
            WebPaywallDiagnostics.log(environment, "resource.invalid", "key=\(key)")
            guard (leases[key] ?? 0) == 0 else { throw WebPaywallError.invalidDocument }
            guard let trash = WebPaywallCacheMaintenance.quarantine(directory) else {
                throw WebPaywallError.invalidDocument
            }
            // 只等待后台删除当前坏目录；actor 可继续处理其他包和租约。
            let removed = await cleanup(trash)
            if removed == nil && FileManager.default.fileExists(atPath: trash.path) {
                throw WebPaywallError.invalidDocument
            }
        }
        WebPaywallDiagnostics.log(environment, "resource.download_wait", "key=\(key) active=\(downloads)")
        await acquireDownload()
        defer { finishDownload() }
        return try await download(directory, identity, environment, timeout: timeout, manifestData: manifestData)
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
                          timeout: TimeInterval, manifestData: Data?) async throws -> URL {
        WebPaywallDiagnostics.log(environment, "resource.download_start", "key=\(destination.lastPathComponent)")
        let fm = FileManager.default
        let temporary = root.appendingPathComponent("tmp-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        let cleanup = self.cleanup
        // 成功时临时目录已改名；失败时任务组已退出，隔离后由后台负责递归删除。
        defer {
            if let trash = WebPaywallCacheMaintenance.quarantine(temporary) {
                Task { _ = await cleanup(trash) }
            }
        }
        let base = URL(string: identity.pageUrl)!.deletingLastPathComponent()
        let deadline = Date().addingTimeInterval(timeout)
        // 同包共享一个连接池；结束后只释放本包传输，不影响其他包或共享等待者。
        let transport = self.fetch == nil ? WebPaywallResourceDownload() : nil
        defer { transport?.close() }
        let fetch: @Sendable (URL, Int, Date) async throws -> Data = self.fetch ?? { url, limit, deadline in
            try await transport!.fetch(url, limit: limit, deadline: deadline)
        }
        let data: Data
        if let manifestData { data = manifestData }
        else { data = try await fetch(base.appendingPathComponent("package.json"), 256_000, deadline) }
        let package = try WebPaywallPackage.parse(data, identity: identity, environment: environment)
        // 包内并发下载仍逐项校验，失败时任务组先停止，随后清理临时目录。
        try await downloadFiles(package.files, base: base, directory: temporary, deadline: deadline, fetch: fetch)
        try Task.checkCancellation()
        try data.write(to: temporary.appendingPathComponent("package.json"))
        try fm.moveItem(at: temporary, to: destination)
        WebPaywallDiagnostics.log(environment, "resource.download_ready", "key=\(destination.lastPathComponent) files=\(package.files.count)")
        schedulePrune(limit: capacity)
        return destination
    }

    /// 最多四个资源请求并行，所有文件成功后才允许上层原子提交。
    private func downloadFiles(_ files: [WebPaywallPackage.File], base: URL,
                               directory: URL, deadline: Date,
                               fetch: @escaping @Sendable (URL, Int, Date) async throws -> Data) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func enqueue(_ file: WebPaywallPackage.File) {
                group.addTask {
                    try Task.checkCancellation()
                    let bytes = try await fetch(base.appendingPathComponent(file.path), file.size, deadline)
                    guard bytes.count == file.size, WebPaywallPackage.digest(bytes) == file.sha256 else {
                        throw WebPaywallError.invalidDocument
                    }
                    try Task.checkCancellation()
                    let target = directory.appendingPathComponent(file.path)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try bytes.write(to: target)
                }
            }
            while next < min(4, files.count) { enqueue(files[next]); next += 1 }
            while try await group.next() != nil {
                try Task.checkCancellation()
                if next < files.count { enqueue(files[next]); next += 1 }
            }
        }
    }

    /// 同包共享在途完整校验，不同包独立后台读取，不阻塞下载调度和租约释放。
    private func verify(_ directory: URL, key: String, identity: WebPaywallPackage.Document,
                        environment: String) async throws {
        if verifications[key] == nil {
            let beforeVerify = self.beforeVerify
            verifications[key] = (UUID(), Task.detached(priority: .userInitiated) {
                try await WebPaywallDiagnostics.measure(environment, "resource.verify", "key=\(key) document=\(identity.documentId)") {
                    await beforeVerify?(directory)
                    try WebPaywallPackage.verify(directory, identity: identity, environment: environment)
                }
            })
        }
        let pending = verifications[key]!
        defer {
            if verifications[key]?.id == pending.id { verifications[key] = nil }
        }
        try await pending.task.value
        try Task.checkCancellation()
    }

    /// 多个释放和下载完成合并清理，手动清理的零容量要求优先。
    private func schedulePrune(limit: Int) {
        pendingPruneLimit = min(pendingPruneLimit ?? limit, limit)
        guard pruning == nil else { return }
        pruning = Task { await self.drainPrune() }
    }

    /// 扫描在后台执行；每次删除前在仓库执行器重新确认当前租约。
    private func drainPrune() async {
        defer { pruning = nil }
        while let limit = pendingPruneLimit {
            pendingPruneLimit = nil
            let entries: [WebPaywallCacheMaintenance.Entry]
            if let scan { entries = await scan(root) }
            else { entries = await WebPaywallCacheMaintenance.entries(at: root, measureSize: true) }
            var total = entries.reduce(0) { $0 + $1.size }
            for entry in entries where total > limit {
                let key = entry.directory.lastPathComponent
                // 检查与隔离之间不能 await，避免新租约插入后被误删。
                guard (pins[key] ?? 0) == 0,
                      let trash = WebPaywallCacheMaintenance.quarantine(entry.directory) else { continue }
                total -= entry.size
                if let environment = await WebPaywallCacheMaintenance.remove(trash) {
                    WebPaywallDiagnostics.log(environment, "resource.evicted",
                        "key=\(key) bytes=\(entry.size) limit=\(limit)")
                }
            }
        }
    }
}
