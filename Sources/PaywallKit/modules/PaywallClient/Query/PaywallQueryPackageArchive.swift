import Foundation

/// 大资源包的复制与摘要复验在独立执行器完成，避免静默更新阻塞界面。
actor PaywallQueryPackageArchive {
    /// 临时包完整复验后才发布；活跃包不允许在原路径替换。
    func publish(_ snapshot: PaywallQuerySnapshot, source: URL, root: URL,
                 environment: String, canReplace: Bool) throws {
        let target = root.appendingPathComponent(snapshot.packageKey, isDirectory: true)
        if (try? WebPaywallPackage.verify(target, identity: snapshot.identity, environment: environment)) != nil { return }
        guard canReplace else { throw PaywallFailure.resource }
        try Task.checkCancellation()
        let fm = FileManager.default
        let temporary = root.appendingPathComponent("tmp-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        // 索引尚未提交前只操作临时目录，进程中断不影响原来的启动版本。
        try fm.copyItem(at: source, to: temporary)
        try WebPaywallPackage.verify(temporary, identity: snapshot.identity, environment: environment)
        try Task.checkCancellation()
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: temporary, to: target)
    }
}
