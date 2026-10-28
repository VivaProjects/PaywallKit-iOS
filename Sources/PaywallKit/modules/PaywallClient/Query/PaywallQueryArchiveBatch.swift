import Foundation

/// 单次查询持有已归档包的租约，多个别名只复制和校验一次。
@MainActor
final class PaywallQueryArchiveBatch {
    struct Package {
        let document: WebPaywallDocument
        let lease: WebPaywallResourceLease
    }
    private var packages: [String: Task<Package, Error>] = [:]

    deinit { packages.values.forEach { $0.cancel() } }

    /// 调用者继续独立提交点位索引和校验授权，不跨查询保存验证结果。
    func load(_ key: String, operation: @escaping () async throws -> Package) async throws -> Package {
        if packages[key] == nil { packages[key] = Task { try await operation() } }
        let pending = packages[key]!
        let value: Package
        do { value = try await pending.value }
        catch {
            // 失败不成为批次内永久缓存，后续点位保留原来的归档机会。
            if packages[key] == pending { packages.removeValue(forKey: key) }
            throw error
        }
        try Task.checkCancellation()
        return value
    }
}
