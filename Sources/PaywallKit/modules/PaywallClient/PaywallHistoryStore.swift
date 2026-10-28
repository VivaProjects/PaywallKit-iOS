import Foundation

/// 成功页面独立归档，普通资源 LRU 清理不会删除最近两个成功版本。
actor PaywallHistoryStore {
    static let shared = PaywallHistoryStore()
    struct Candidate {
        let snapshot: PaywallHistorySnapshot
        let identity: WebPaywallPackage.Document
        let lease: WebPaywallResourceLease
        let document: WebPaywallDocument
    }

    private struct Record: Codable {
        let snapshot: PaywallHistorySnapshot
        let identity: WebPaywallPackage.Document
        let directory: String
    }

    private let root: URL
    private var leases: [String: Int] = [:]

    init(directory: URL? = nil) {
        root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaywallKit/SuccessfulVersions", isDirectory: true)
    }

    /// 首屏成功且资源完整才提交记录；中途取消保留原来的成功版本。
    func record(_ snapshot: PaywallHistorySnapshot, placement: String,
                document: WebPaywallDocument, packageDirectory: URL? = nil) async throws {
        guard document.localReadAccessURL == nil else { return }
        let identity = try WebPaywallPackage.identity(document)
        // 查询快照来自独立缓存目录；普通页面继续只读取已下载完成的共享资源。
        let resource: WebPaywallResourceLease
        if let packageDirectory {
            try WebPaywallPackage.verify(packageDirectory, identity: identity, environment: snapshot.environment)
            resource = WebPaywallResourceLease(directory: packageDirectory, release: {})
        } else {
            resource = try await WebPaywallResourceCache.shared.cachedPackage(
                document: document, environment: snapshot.environment)
        }
        try Task.checkCancellation()
        let group = snapshot.key(placement: placement, documentID: identity.documentId)
        let directory = try prepareDirectory(group)
        let previous = records(in: directory)
        // 同版本不同内容不能覆盖已经成功且可能仍在展示的包。
        if previous.contains(where: { $0.identity.revision == identity.revision }) { return }
        let packageKey = WebPaywallPackage.digest(try JSONEncoder().encode(identity))
        let record = Record(snapshot: snapshot, identity: identity, directory: packageKey)
        let next = Array((previous + [record]).sorted { $0.identity.revision > $1.identity.revision }.prefix(2))
        guard next.contains(where: { $0.directory == packageKey }) else { return }
        try archive(resource.readAccessURL, to: directory.appendingPathComponent(packageKey),
                    identity: identity, environment: snapshot.environment)
        try Task.checkCancellation()
        try JSONEncoder().encode(next).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        prune(group)
        WebPaywallDiagnostics.log(snapshot.environment, "history.recorded",
                                  "placement=\(placement) revision=\(identity.revision)")
    }

    /// 只尝试同文档最近一个更低版本；校验失败交由上层进入 Settings。
    func previous(_ snapshot: PaywallHistorySnapshot, placement: String,
                  document: WebPaywallDocument) async throws -> Candidate? {
        guard let revision = document.revision else { return nil }
        let group = snapshot.key(placement: placement, documentID: document.documentId)
        let directory = root.appendingPathComponent(group)
        guard let record = records(in: directory)
            .filter({ $0.identity.documentId == document.documentId && $0.identity.revision < revision })
            .max(by: { $0.identity.revision < $1.identity.revision }) else { return nil }
        guard record.snapshot.key(placement: placement, documentID: document.documentId) == group,
              validDirectory(record.directory) else { throw PaywallFailure.resource }
        let package = directory.appendingPathComponent(record.directory)
        let key = group + "/" + record.directory
        leases[key, default: 0] += 1
        let lease = WebPaywallResourceLease(directory: package) { Task { await self.release(key, group: group) } }
        // 先持有租约再离开 actor，后台验证期间记录清理不能删除候选目录。
        let document = try await WebPaywallLocalDocumentLoader.load(directory: package,
            identity: record.identity, environment: snapshot.environment,
            catalog: PaywallCatalog(productRefs: record.identity.productRefs, recommendedRef: record.identity.initialProductRef))
        return Candidate(snapshot: record.snapshot, identity: record.identity, lease: lease, document: document)
    }

    /// 独立目录排除系统备份，目录名只接受内容摘要。
    private func prepareDirectory(_ group: String) throws -> URL {
        let directory = root.appendingPathComponent(group, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL else {
            throw PaywallFailure.resource
        }
        var location = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try location.setResourceValues(values)
        return directory
    }

    /// 完整拷贝并校验后原子替换，不让半包进入成功索引。
    private func archive(_ source: URL, to destination: URL, identity: WebPaywallPackage.Document,
                         environment: String) throws {
        if (try? WebPaywallPackage.verify(destination, identity: identity, environment: environment)) != nil { return }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("tmp-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        try WebPaywallPackage.verify(temporary, identity: identity, environment: environment)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    /// 索引不可读视为无历史，不从普通磁盘缓存猜测成功状态。
    private func records(in directory: URL) -> [Record] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
              data.count <= 3_000_000,
              let records = try? JSONDecoder().decode([Record].self, from: data), records.count <= 2 else { return [] }
        return records
    }

    /// 活跃历史页持有租约，直到 WebView 退出后才允许删除被替换的包。
    private func release(_ key: String, group: String) {
        leases[key] = max(0, (leases[key] ?? 1) - 1)
        prune(group)
    }

    /// 仅清理当前组的非索引包，保留所有正在使用的历史页。
    private func prune(_ group: String) {
        let directory = root.appendingPathComponent(group)
        let kept = Set(records(in: directory).map(\.directory))
        guard let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for child in children where validDirectory(child.lastPathComponent)
            && !kept.contains(child.lastPathComponent) && (leases[group + "/" + child.lastPathComponent] ?? 0) == 0 {
            try? FileManager.default.removeItem(at: child)
        }
    }

    /// 不接受索引中的绝对路径或父目录跳转。
    private func validDirectory(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }
}
