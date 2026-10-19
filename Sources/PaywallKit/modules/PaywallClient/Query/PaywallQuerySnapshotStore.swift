import Foundation

/// 查询缓存使用独立完整包目录，后台写入不会改变本次进程已持有的版本。
@MainActor
final class PaywallQuerySnapshotStore {
    struct Candidate {
        let snapshot: PaywallQuerySnapshot
        let lease: WebPaywallResourceLease
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
    private(set) var hasIndex = false

    /// 环境、接口、应用版本及稳定设备条件隔离；渠道和国家保留在各自请求身份中。
    init(configuration: PaywallQueryConfiguration) {
        environment = configuration.runtimeEnvironment.rawValue
        let scope = [configuration.cacheScope, configuration.endpoint.absoluteString,
                     Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                     WebPaywallEnvironment.deviceModelIdentifier(), Locale.preferredLanguages.first ?? ""]
        let key = WebPaywallPackage.digest((try? JSONEncoder().encode(scope)) ?? Data())
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaywallKit/QuerySnapshots/\(key)", isDirectory: true)
    }

    /// 只读取本地索引与完整资源，单个坏点位不会阻塞其他点位恢复。
    func restore() -> [Candidate] {
        guard root.resolvingSymlinksInPath().standardizedFileURL == root.standardizedFileURL else { return [] }
        let file = root.appendingPathComponent("index.json")
        hasIndex = FileManager.default.fileExists(atPath: file.path)
        guard let bytes = try? Data(contentsOf: file), bytes.count <= 16_000_000,
              let index = try? JSONDecoder().decode(Index.self, from: bytes),
              index.version == 1, index.environment == environment, index.snapshots.count <= 100 else { return [] }
        snapshots = index.snapshots.filter { $0.key == $0.value.placement }
        // 资源复验失败只视为该点位缺失，不删除仍可能被旧会话持有的包。
        return snapshots.values.compactMap { snapshot in
            let directory = packageDirectory(snapshot.packageKey)
            guard (try? WebPaywallPackage.verify(directory, identity: snapshot.identity,
                                                 environment: environment)) != nil else { return nil }
            return Candidate(snapshot: snapshot, lease: retain(snapshot.packageKey))
        }
    }

    /// 完整拷贝和校验后原子提交点位索引，任何失败都保留原来的可用记录。
    func save(_ snapshot: PaywallQuerySnapshot, resource: WebPaywallResourceLease) async throws -> Candidate {
        try prepareRoot()
        let canReplace = (leases[snapshot.packageKey] ?? 0) == 0
        // 异步归档期间先占租约，目录发布与索引提交之间也不能被清理。
        let lease = retain(snapshot.packageKey)
        try await archive.publish(snapshot, source: resource.readAccessURL, root: root,
                                  environment: environment, canReplace: canReplace)
        try Task.checkCancellation()
        var next = snapshots
        next[snapshot.placement] = snapshot
        try commit(next)
        let candidate = Candidate(snapshot: snapshot, lease: lease)
        prune()
        return candidate
    }

    /// 明确不再匹配只撤销下次启动索引，本次点位快照及其租约继续有效。
    func remove(_ placements: Set<String>) throws {
        guard !hasIndex || placements.contains(where: { snapshots[$0] != nil }) else { return }
        try prepareRoot()
        try commit(snapshots.filter { !placements.contains($0.key) })
        prune()
    }

    /// 写入成功才更新仓库视图，不向当前运行时推送新配置。
    private func commit(_ next: [String: PaywallQuerySnapshot]) throws {
        let index = Index(version: 1, environment: environment, snapshots: next)
        try JSONEncoder().encode(index).write(to: root.appendingPathComponent("index.json"), options: .atomic)
        snapshots = next
        hasIndex = true
    }

    /// 当前及候选页面持有租约时，后续提交不能清理其目录。
    private func retain(_ key: String) -> WebPaywallResourceLease {
        leases[key, default: 0] += 1
        return WebPaywallResourceLease(directory: packageDirectory(key)) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.leases[key] = max(0, (self.leases[key] ?? 1) - 1)
                self.prune()
            }
        }
    }

    /// 仅删除不在下次启动索引内且没有活跃租约的完整包。
    private func prune() {
        let kept = Set(snapshots.values.map(\.packageKey))
        guard let children = try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil) else { return }
        for child in children where child.lastPathComponent.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
            && !kept.contains(child.lastPathComponent) && (leases[child.lastPathComponent] ?? 0) == 0 {
            try? FileManager.default.removeItem(at: child)
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
