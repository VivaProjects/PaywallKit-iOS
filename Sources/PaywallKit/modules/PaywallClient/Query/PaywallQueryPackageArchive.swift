import Foundation

/// 同包串行、不同包最多两个并行；复制与摘要校验不占用调度执行器。
actor PaywallQueryPackageArchive {
    private var tails: [String: (UUID, Task<Void, Never>)] = [:]
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let beforePublish: (@Sendable (URL) async throws -> Void)?
    private let cleanup: @Sendable (URL) async -> String?

    /// 测试可阻塞准备或清理；实际校验和发布始终使用生产路径。
    init(beforePublish: (@Sendable (URL) async throws -> Void)? = nil,
         cleanup: @escaping @Sendable (URL) async -> String? = { await WebPaywallCacheMaintenance.remove($0) }) {
        self.beforePublish = beforePublish
        self.cleanup = cleanup
    }

    /// 同身份等待不占用并发槽；各请求保留独立取消与活跃目录替换条件。
    func publish(_ snapshot: PaywallQuerySnapshot, source: URL, root: URL,
                 environment: String, canReplace: Bool) async throws -> WebPaywallDocument {
        let key = root.path + "/" + snapshot.packageKey
        let previous = tails[key]?.1, token = UUID()
        let started = ProcessInfo.processInfo.systemUptime
        let task = Task {
            await previous?.value
            try Task.checkCancellation()
            await acquire()
            defer { release() }
            WebPaywallDiagnostics.log(environment, "archive.acquired",
                "key=\(snapshot.packageKey) queueMs=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))")
            try Task.checkCancellation()
            return try await execute(snapshot, source: source, root: root,
                                     environment: environment, canReplace: canReplace)
        }
        tails[key] = (token, Task { _ = try? await task.value })
        defer { if tails[key]?.0 == token { tails[key] = nil } }
        return try await WebPaywallDiagnostics.measure(environment, "archive.total", "key=\(snapshot.packageKey)") {
            try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        }
    }

    /// 重文件操作交给后台任务，取消后仍等待写入退出，不能提前复用同包槽位。
    private func execute(_ snapshot: PaywallQuerySnapshot, source: URL, root: URL,
                         environment: String, canReplace: Bool) async throws -> WebPaywallDocument {
        let beforePublish = self.beforePublish, cleanup = self.cleanup
        let worker = Task.detached(priority: .userInitiated) {
            try await beforePublish?(source)
            try Task.checkCancellation()
            return try await WebPaywallDiagnostics.measure(environment, "archive.work", "key=\(snapshot.packageKey)") {
                try Self.write(snapshot, source: source, root: root, environment: environment,
                               canReplace: canReplace, cleanup: cleanup)
            }
        }
        return try await withTaskCancellationHandler(operation: {
            let value = try await worker.value
            try Task.checkCancellation()
            return value
        }, onCancel: { worker.cancel() })
    }

    /// 最多两个独立包准备，失败或取消均将槽位直接交给下一等待者。
    private func acquire() async {
        if active >= 2 { await withCheckedContinuation { waiting.append($0) } }
        else { active += 1 }
    }

    /// 已排队请求先取得槽位，避免新请求抢占导致长期饥饿。
    private func release() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().resume() }
    }

    /// 临时包完整复验后才发布；失败目录先隔离，递归删除不阻塞后续归档。
    private nonisolated static func write(_ snapshot: PaywallQuerySnapshot, source: URL, root: URL,
                                         environment: String, canReplace: Bool,
                                         cleanup: @escaping @Sendable (URL) async -> String?) throws -> WebPaywallDocument {
        let target = root.appendingPathComponent(snapshot.packageKey, isDirectory: true)
        let catalog = PaywallCatalog(productRefs: snapshot.identity.productRefs,
                                     recommendedRef: snapshot.identity.initialProductRef)
        if let document = try? WebPaywallDocument(packageDirectory: target, identity: snapshot.identity,
                                                 environment: environment, catalog: catalog) { return document }
        guard canReplace else { throw PaywallFailure.resource }
        try Task.checkCancellation()
        let fm = FileManager.default
        let temporary = root.appendingPathComponent("tmp-" + UUID().uuidString)
        defer {
            if let trash = WebPaywallCacheMaintenance.quarantine(temporary) {
                Task { _ = await cleanup(trash) }
            }
        }
        try fm.copyItem(at: source, to: temporary)
        let document = try WebPaywallDocument(packageDirectory: temporary, identity: snapshot.identity,
                                             environment: environment, catalog: catalog)
        try Task.checkCancellation()
        try replace(temporary, target: target, cleanup: cleanup)
        return try document.relocatingVerifiedPackage(to: target)
    }

    /// 新目录发布失败恢复原路径；只有成功替换的坏目录才交给后台清理。
    private nonisolated static func replace(_ temporary: URL, target: URL,
                                           cleanup: @escaping @Sendable (URL) async -> String?) throws {
        let fm = FileManager.default
        var backup: URL?
        if fm.fileExists(atPath: target.path) {
            guard let trash = WebPaywallCacheMaintenance.quarantine(target) else { throw PaywallFailure.resource }
            backup = trash
        }
        do { try fm.moveItem(at: temporary, to: target) }
        catch {
            if let backup { try fm.moveItem(at: backup, to: target) }
            throw error
        }
        if let backup { Task { _ = await cleanup(backup) } }
    }
}
