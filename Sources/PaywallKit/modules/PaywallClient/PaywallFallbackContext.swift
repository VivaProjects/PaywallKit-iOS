import Foundation

/// 一次展示依次尝试当前页、同文档旧版本、Settings；取消和禁用优先结束。
@MainActor
final class PaywallFallbackContext {
    let requestedPlacement: String
    let store: PaywallLocalPackageStore?
    let usesPreviousVersion: Bool
    private(set) var deadline = Date().addingTimeInterval(12)
    private(set) var local = false
    private(set) var bundledOnly = false
    private(set) var reason: PaywallFailure?
    private(set) var resolution: PaywallSessionResolution?
    private var current: PaywallPlacement?
    private var previous: PaywallPlacement?
    private var previousLease: WebPaywallResourceLease?
    private var triedPrevious = false
    private let cachedFallback: PaywallPlacement?

    /// 主动点位优先使用自己的启动快照，兜底更新包固定为启动时的版本。
    init(placement: String, store: PaywallLocalPackageStore?, usesPreviousVersion: Bool = false,
         startsLocally: Bool = true, cachedFallback: PaywallPlacement? = nil) {
        requestedPlacement = placement
        self.store = store
        self.usesPreviousVersion = usesPreviousVersion
        self.cachedFallback = cachedFallback
        local = startsLocally && store?.placement == placement
    }

    /// 冻结目标文档，不能用后续刷新后的映射寻找其他 H5 的历史。
    func capture(_ selected: PaywallPlacement) {
        guard !local, previous == nil else { return }
        var snapshot = selected
        snapshot.fallbackContext = nil
        current = snapshot
    }

    /// 手动重试继续当前历史分支，保留资源租约与首次失败归因。
    func previousPlacement() -> PaywallPlacement? {
        guard !local, var selected = previous else { return nil }
        selected.fallbackContext = self
        return selected
    }

    /// 本地页面整体替换绑定，仍保留原入口和原展示容器。
    func localPlacement(clientID: UUID) throws -> PaywallPlacement {
        guard let store, !store.isDisabled(requestedPlacement) else { throw PaywallFailure.disabled }
        if !bundledOnly, let cachedFallback {
            resolution = PaywallSessionResolution(requestedPlacement: requestedPlacement,
                documentID: cachedFallback.document.documentId, revision: cachedFallback.document.revision ?? 0,
                source: "update", fallbackReason: reason?.rawValue)
            var selected = PaywallPlacement(name: requestedPlacement, document: cachedFallback.document,
                presentation: .fullScreen, sessionPolicy: nil, clientID: clientID, fallbackContext: self)
            selected.resourceLease = cachedFallback.resourceLease
            return selected
        }
        let (document, source) = try store.selection(bundledOnly: bundledOnly)
        resolution = PaywallSessionResolution(requestedPlacement: requestedPlacement, documentID: document.documentId,
                                       revision: document.revision ?? 0, source: source, fallbackReason: reason?.rawValue)
        return PaywallPlacement(name: requestedPlacement, document: document, presentation: .fullScreen,
                                sessionPolicy: nil, clientID: clientID, fallbackContext: self)
    }

    /// 只有显式开启的点位把商品失败纳入降级，其他点位保持原策略。
    func advance(_ failure: PaywallFailure, client: PaywallClient) async throws -> PaywallPlacement? {
        try Task.checkCancellation()
        guard !client.isPlacementDisabled(requestedPlacement) else { throw PaywallFailure.disabled }
        guard failure.permitsFallback || (usesPreviousVersion && failure == .productsUnavailable),
              let store else { return nil }
        reason = reason ?? failure
        if !local {
            guard store.placement == requestedPlacement || store.fallbackPlacements.contains(requestedPlacement) else { return nil }
            if let selected = try await tryPrevious(client: client) { return selected }
            // 兜底点位自己的启动快照失败后直接回到内置包，不能重试同一坏包。
            if store.placement == requestedPlacement { bundledOnly = true }
            local = true
        } else {
            guard !bundledOnly, resolution?.source == "update" else { return nil }
            bundledOnly = true
        }
        // 历史页退出前保留租约，避免 WebView 退场时读到已删除文件。
        deadline = Date().addingTimeInterval(12)
        return try localPlacement(clientID: client.id)
    }

    /// 一次展示最多选择一个旧版本，损坏、缺失或不兼容直接进入 Settings。
    private func tryPrevious(client: PaywallClient) async throws -> PaywallPlacement? {
        guard usesPreviousVersion, !triedPrevious else { return nil }
        triedPrevious = true
        guard let current else { return nil }
        do {
            guard let (selected, lease) = try await client.previousPlacement(current) else { return nil }
            try Task.checkCancellation()
            previous = selected
            previousLease = lease
            deadline = Date().addingTimeInterval(12)
            resolution = PaywallSessionResolution(requestedPlacement: requestedPlacement,
                documentID: selected.document.documentId, revision: selected.document.revision ?? 0,
                source: "previous_version", fallbackReason: reason?.rawValue)
            return previousPlacement()
        } catch is CancellationError { throw CancellationError() }
        catch PaywallFailure.disabled { throw PaywallFailure.disabled }
        catch { return nil }
    }

    /// 配置就绪或当前分支重试时重新计页面准备期限，不计入此前的缓存等待时间。
    func beginPreparation() { deadline = Date().addingTimeInterval(12) }

    /// 来源回调不得把历史页或本地兜底的失败归因覆盖成普通磁盘命中。
    func record(_ document: WebPaywallDocument, source: String = "remote_or_cache") {
        guard !local, previous == nil else { return }
        resolution = PaywallSessionResolution(requestedPlacement: requestedPlacement, documentID: document.documentId,
                                       revision: document.revision ?? 0, source: source, fallbackReason: nil)
    }
}
