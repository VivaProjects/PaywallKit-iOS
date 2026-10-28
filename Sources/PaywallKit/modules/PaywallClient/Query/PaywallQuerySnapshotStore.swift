import Foundation

/// 查询缓存使用独立完整包目录，后台写入不会改变本次进程已持有的版本。
@MainActor
final class PaywallQuerySnapshotStore {
    struct Candidate {
        let snapshot: PaywallQuerySnapshot
        let lease: WebPaywallResourceLease
        let document: WebPaywallDocument
    }

    private struct Index: Codable {
        let version: Int
        let environment: String
        let snapshots: [String: PaywallQuerySnapshot]
    }

    private let root: URL
    private let environment: String
    private let archive = PaywallQueryPackageArchive()
    private var snapshots: [String: PaywallQuerySnapshot] = [:]
    private var leases: [String: Int] = [:]
    private let scan: (@Sendable (URL) async -> [WebPaywallCacheMaintenance.Entry])?
    private var pruning: Task<Void, Never>?
    private var pruneRequested = false
    private var commitTail: Task<Void, Never>?
    private let beforeIndexWrite: (@Sendable () async throws -> Void)?
    private(set) var hasIndex = false

    /// 目录由所有者提供，读取校验仍使用相同环境和资源身份。
    init(directory: URL, environment: String,
         scan: (@Sendable (URL) async -> [WebPaywallCacheMaintenance.Entry])? = nil,
         beforeIndexWrite: (@Sendable () async throws -> Void)? = nil) {
        root = directory
        self.environment = environment
        self.scan = scan
        self.beforeIndexWrite = beforeIndexWrite
    }

    private var indexTask: Task<Index?, Never>?
    private var indexLoaded = false
    private var opening: [String: Task<WebPaywallDocument?, Never>] = [:]

    deinit {
        indexTask?.cancel()
        opening.values.forEach { $0.cancel() }
    }

    /// 索引读取和解码离开主线程；写入前必须先完成启动索引冻结。
    private func loadIndex() async {
        if indexLoaded { return }
        if indexTask == nil {
            let root = self.root, environment = self.environment
            indexTask = Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled,
                      root.resolvingSymlinksInPath().standardizedFileURL == root.standardizedFileURL,
                      let bytes = try? Data(contentsOf: root.appendingPathComponent("index.json")),
                      bytes.count <= 16_000_000,
                      let index = try? JSONDecoder().decode(Index.self, from: bytes),
                      index.version == 1, index.environment == environment,
                      index.snapshots.count <= 100 else { return nil }
                return index
            }
            // 保留旧语义：存在但损坏的索引也不能触发历史配置迁移。
            hasIndex = FileManager.default.fileExists(atPath: root.appendingPathComponent("index.json").path)
        }
        let index = await indexTask!.value
        guard !indexLoaded else { return }
        snapshots = index?.snapshots.filter { $0.key == $0.value.placement } ?? [:]
        indexLoaded = true
    }

    /// 仅列出冻结的启动点位；资源由调用方按可见入口优先调度。
    func restoreNames() async -> [String] {
        await loadIndex()
        return snapshots.keys.sorted()
    }

    /// 每个完整包共用一个后台校验任务；每个点位仍独立验证配置权限。
    func restore(_ name: String, catalog: PaywallCatalog) async -> Candidate? {
        await loadIndex()
        guard !Task.isCancelled, let snapshot = snapshots[name] else { return nil }
        let key = snapshot.packageKey
        if opening[key] == nil {
            let directory = packageDirectory(key), environment = self.environment
            opening[key] = Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return nil }
                return try? WebPaywallDocument(packageDirectory: directory, identity: snapshot.identity,
                                               environment: environment, catalog: catalog)
            }
        }
        guard let document = await opening[key]!.value, !Task.isCancelled else { return nil }
        return Candidate(snapshot: snapshot, lease: retain(key), document: document)
    }

    /// 完整拷贝和校验后原子提交点位索引，任何失败都保留原来的可用记录。
    func save(_ snapshot: PaywallQuerySnapshot, resource: WebPaywallResourceLease,
              batch: PaywallQueryArchiveBatch? = nil) async throws -> Candidate {
        await loadIndex()
        try prepareRoot()
        let package: PaywallQueryArchiveBatch.Package
        if let batch {
            package = try await batch.load(environment + ":" + root.path + "/" + snapshot.packageKey) {
                try await self.publish(snapshot, resource: resource)
            }
        } else { package = try await publish(snapshot, resource: resource) }
        try Task.checkCancellation()
        try await commit { current in
            var next = current
            next[snapshot.placement] = snapshot
            return next
        }
        let candidate = Candidate(snapshot: snapshot, lease: package.lease, document: package.document)
        schedulePrune()
        return candidate
    }

    /// 明确不再匹配只撤销下次启动索引，本次点位快照及其租约继续有效。
    func remove(_ placements: Set<String>) async throws {
        await loadIndex()
        try prepareRoot()
        try await commit { current in
            guard !self.hasIndex || placements.contains(where: { current[$0] != nil }) else { return nil }
            return current.filter { !placements.contains($0.key) }
        }
        schedulePrune()
    }

    /// 写入成功才更新仓库视图，不向当前运行时推送新配置。
    private func commit(_ change: @escaping ([String: PaywallQuerySnapshot]) -> [String: PaywallQuerySnapshot]?) async throws {
        let previous = commitTail
        let task = Task {
            await previous?.value
            try Task.checkCancellation()
            // 排到本次提交时才读取最新状态，异步写入不能丢失其他点位的更新。
            guard let next = change(snapshots) else { return }
            let index = Index(version: 1, environment: environment, snapshots: next)
            let file = root.appendingPathComponent("index.json"), beforeWrite = beforeIndexWrite
            let writing = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                try await beforeWrite?()
                let bytes = try JSONEncoder().encode(index)
                try Task.checkCancellation()
                try bytes.write(to: file, options: .atomic)
            }
            try await withTaskCancellationHandler(operation: { try await writing.value },
                                                 onCancel: { writing.cancel() })
            // 落盘完成后同步内存，即使调用者此时取消也不让两份索引分叉。
            snapshots = next
            hasIndex = true
        }
        commitTail = Task { _ = try? await task.value }
        try await WebPaywallDiagnostics.measure(environment, "snapshot.commit") {
            try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        }
    }

    /// 发布期间先占租约，批次和当前页面都能保护已校验的不可变目录。
    private func publish(_ snapshot: PaywallQuerySnapshot, resource: WebPaywallResourceLease) async throws -> PaywallQueryArchiveBatch.Package {
        let canReplace = (leases[snapshot.packageKey] ?? 0) == 0
        let lease = retain(snapshot.packageKey)
        let document = try await archive.publish(snapshot, source: resource.readAccessURL, root: root,
                                                environment: environment, canReplace: canReplace)
        return .init(document: document, lease: lease)
    }

    /// 当前及候选页面持有租约时，后续提交不能清理其目录。
    private func retain(_ key: String) -> WebPaywallResourceLease {
        leases[key, default: 0] += 1
        return WebPaywallResourceLease(directory: packageDirectory(key)) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.leases[key] = max(0, (self.leases[key] ?? 1) - 1)
                self.schedulePrune()
            }
        }
    }

    /// 合并后台清理请求，不让递归删除阻塞快照交付和页面关闭。
    private func schedulePrune() {
        pruneRequested = true
        guard pruning == nil else { return }
        pruning = Task { [weak self] in await self?.drainPrune() }
    }

    /// 后台扫描完成后使用最新索引和租约重新判断，隔离后才异步删除。
    private func drainPrune() async {
        defer { pruning = nil }
        while pruneRequested {
            pruneRequested = false
            let entries: [WebPaywallCacheMaintenance.Entry]
            if let scan { entries = await scan(root) }
            else { entries = await WebPaywallCacheMaintenance.entries(at: root, measureSize: false) }
            for entry in entries {
                let key = entry.directory.lastPathComponent
                // 主线程只做原子改名；复制中的候选包也有预留租约。
                guard !snapshots.values.contains(where: { $0.packageKey == key }),
                      (leases[key] ?? 0) == 0,
                      let trash = WebPaywallCacheMaintenance.quarantine(entry.directory) else { continue }
                _ = await WebPaywallCacheMaintenance.remove(trash)
            }
        }
    }

    /// SDK 私有缓存排除备份，并拒绝根目录符号链接逃逸。
    private func prepareRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard root.resolvingSymlinksInPath().standardizedFileURL == root.standardizedFileURL else {
            throw PaywallFailure.resource
        }
        var location = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try location.setResourceValues(values)
    }

    /// 包目录名仅由 SDK 从完整身份摘要生成。
    private func packageDirectory(_ key: String) -> URL { root.appendingPathComponent(key, isDirectory: true) }
}
