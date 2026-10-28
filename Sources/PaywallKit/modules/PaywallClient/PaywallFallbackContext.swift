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
    private var localHandoffAvailable = false
    private var cachedFallback: PaywallPlacement?

    private var prepareLaunch: (() async throws -> Bool)?

    /// 主动点位优先使用自己的启动快照，兜底更新包固定为启动时的版本。
    init(placement: String, store: PaywallLocalPackageStore?, usesPreviousVersion: Bool = false,
         startsLocally: Bool = true, cachedFallback: PaywallPlacement? = nil,
         prepareLaunch: (() async throws -> Bool)? = nil) {
        requestedPlacement = placement
        self.store = store
        self.usesPreviousVersion = usesPreviousVersion
        self.cachedFallback = cachedFallback
        self.prepareLaunch = prepareLaunch
        local = prepareLaunch == nil && startsLocally && store?.placement == placement
    }

    /// 尚未校验不等于缓存缺失；仅首次选择时确定本地分支。
    func prepareLaunchSelection() async throws {
        guard let prepareLaunch else { return }
        let hasSnapshot = try await prepareLaunch()
        try Task.checkCancellation()
        self.prepareLaunch = nil
        local = !hasSnapshot && store?.placement == requestedPlacement
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
    func localPlacement(clientID: UUID) async throws -> PaywallPlacement {
        guard let store, !store.isDisabled(requestedPlacement) else { throw PaywallFailure.disabled }
        if !bundledOnly, let cachedFallback {
            resolution = PaywallSessionResolution(requestedPlacement: requestedPlacement,
                documentID: cachedFallback.document.documentId, revision: cachedFallback.document.revision ?? 0,
                source: "update", fallbackReason: reason?.rawValue)
            var selected = PaywallPlacement(name: requestedPlacement, document: cachedFallback.document,
                presentation: .fullScreen, sessionPolicy: nil, clientID: clientID, fallbackContext: self)
            selected.resourceLease = cachedFallback.resourceLease
            localHandoffAvailable = true
            return selected
        }
        let onlyBundled = bundledOnly
        let (document, source, lease) = try await store.selection(bundledOnly: onlyBundled)
        try Task.checkCancellation()
        // 异步等待期间若已进入内置分支，旧更新包不能覆盖新的回退决定。
        if onlyBundled != bundledOnly { return try await localPlacement(clientID: clientID) }
        guard !store.isDisabled(requestedPlacement) else { throw PaywallFailure.disabled }
        resolution = PaywallSessionResolution(requestedPlacement: requestedPlacement, documentID: document.documentId,
                                       revision: document.revision ?? 0, source: source, fallbackReason: reason?.rawValue)
        var selected = PaywallPlacement(name: requestedPlacement, document: document, presentation: .fullScreen,
                                sessionPolicy: nil, clientID: clientID, fallbackContext: self)
        selected.resourceLease = lease
        localHandoffAvailable = true
        return selected
    }

    /// 入口到内部会话一次性交接已验证包，不把本次结果变成跨展示验证缓存。
    func takeLocalPlacement(_ selected: PaywallPlacement, clientID: UUID) throws -> PaywallPlacement? {
        guard localHandoffAvailable else { return nil }
        localHandoffAvailable = false
        try Task.checkCancellation()
        guard let store, !store.isDisabled(requestedPlacement) else { throw PaywallFailure.disabled }
        guard local, selected.name == requestedPlacement, selected.clientID == clientID,
              selected.fallbackContext === self, let lease = selected.resourceLease,
              lease.readAccessURL == selected.document.localReadAccessURL,
              let resolution, resolution.documentID == selected.document.documentId,
              resolution.revision == selected.document.revision else { return nil }
        if !bundledOnly, let cachedFallback, lease === cachedFallback.resourceLease {
            try store.validateCurrentCatalog(selected.document)
            return selected
        }
        return try store.canReuseSelection(selected.document, source: resolution.source,
            bundledOnly: bundledOnly) ? selected : nil
    }

    /// 只有显式开启的点位把商品失败纳入降级，其他点位保持原策略。
    func advance(_ failure: PaywallFailure, client: PaywallClient) async throws -> PaywallPlacement? {
        try Task.checkCancellation()
        guard !client.isPlacementDisabled(requestedPlacement) else { throw PaywallFailure.disabled }
        guard failure.permitsFallback || (usesPreviousVersion && failure == .productsUnavailable),
              let store else { return nil }
        localHandoffAvailable = false
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
        if !bundledOnly { cachedFallback = try await client.launchFallback(store.placement) ?? cachedFallback }
        // 历史页退出前保留租约，避免 WebView 退场时读到已删除文件。
        deadline = Date().addingTimeInterval(12)
        let selected = try await localPlacement(clientID: client.id)
        guard !client.isPlacementDisabled(requestedPlacement) else { throw PaywallFailure.disabled }
        return selected
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
    func beginPreparation() {
        localHandoffAvailable = false
        deadline = Date().addingTimeInterval(12)
    }

    /// 来源回调不得把历史页或本地兜底的失败归因覆盖成普通磁盘命中。
    func record(_ document: WebPaywallDocument, source: String = "remote_or_cache") {
        guard !local, previous == nil else { return }
        resolution = PaywallSessionResolution(requestedPlacement: requestedPlacement, documentID: document.documentId,
                                       revision: document.revision ?? 0, source: source, fallbackReason: nil)
    }
}
