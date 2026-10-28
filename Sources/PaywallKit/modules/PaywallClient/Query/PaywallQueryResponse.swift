import Foundation

/// 服务端只下发点位与页面地址；每个点位独立保留自己的完整页面身份。
struct PaywallQueryResponse: Decodable {
    struct Position: Decodable {
        let positionKey: String
        let matched: Bool
        let h5Url: String?
        let displayModeKey: String?
    }
    struct Page {
        let placement: String
        let document: WebPaywallDocument
        let presentation: WebPaywallConfiguration.Presentation
        let resource: WebPaywallResourceLease
    }
    struct Batch {
        let pages: [Page]
        let unmatched: Set<String>
        var failures: Int = 0
    }
    let code: String
    let data: [Position]?

    private struct PackageRequest {
        let url: URL
        var targets: [(placement: String, presentation: WebPaywallConfiguration.Presentation)]
    }

    /// 两个工作者共用队列，点击点位优先占用下一个空闲下载槽。
    @MainActor
    private final class DownloadQueue {
        var pending: [PackageRequest]
        var completed = 0
        var failures = 0
        var inFlight = 0
        let preferredPlacement: @MainActor () -> String?

        init(_ pending: [PackageRequest], preferredPlacement: @escaping @MainActor () -> String?) {
            self.pending = pending
            self.preferredPlacement = preferredPlacement
        }

        /// 已开始的包继续完成；优先级变化只调整尚未开始的任务。
        func next() -> PackageRequest? {
            guard !pending.isEmpty, completed + inFlight < 8 else { return nil }
            let preferred = preferredPlacement()
            let index = pending.firstIndex { request in
                request.targets.contains { $0.placement == preferred }
            } ?? 0
            inFlight += 1
            return pending.remove(at: index)
        }
    }

    /// 先通知响应中不可用的点位，再并发下载并逐个提交完整包。
    @MainActor
    static func load(_ bytes: Data, configuration: PaywallQueryConfiguration,
                     catalog: PaywallCatalog, maximumConcurrentPackages: Int = 1,
                     preferredPlacement: @escaping @MainActor () -> String? = { nil },
                     onUnavailable: (@MainActor (Set<String>) -> Void)? = nil,
                     onPage: (@MainActor (Page) async throws -> Void)? = nil) async throws -> Batch {
        let response = try JSONDecoder().decode(Self.self, from: bytes)
        guard response.code == "200", let positions = response.data, positions.count <= 100 else {
            throw WebPaywallError.invalidDocument
        }
        let selection = packageRequests(positions, configuration: configuration)
        try Task.checkCancellation()
        // 未返回、未命中或无法形成下载任务的点位，不等待其他页面资源。
        let pendingPlacements = Set(selection.packages.flatMap { $0.targets.map { $0.placement } })
        onUnavailable?(Set(configuration.placements.values).subtracting(pendingPlacements))
        // 通知只结束对应入口的等待，已命中的包继续共用原下载队列。
        let queue = DownloadQueue(selection.packages, preferredPlacement: preferredPlacement)
        let pages = try await withThrowingTaskGroup(of: [Page].self) { group in
            for _ in 0..<min(2, max(1, maximumConcurrentPackages)) {
                group.addTask { @MainActor in
                    try await drain(queue, configuration: configuration, catalog: catalog, onPage: onPage)
                }
            }
            var pages: [Page] = []
            for try await result in group { pages.append(contentsOf: result) }
            return pages
        }
        return Batch(pages: pages, unmatched: selection.unmatched, failures: queue.failures)
    }

    private struct PreparedPackage {
        let request: PackageRequest
        let document: WebPaywallDocument
        let resource: WebPaywallResourceLease
    }

    /// 每个工作者只预取一个包，归档当前包时下一包可下载，结构化任务负责取消与释放。
    @MainActor
    private static func drain(_ queue: DownloadQueue, configuration: PaywallQueryConfiguration,
                              catalog: PaywallCatalog,
                              onPage: (@MainActor (Page) async throws -> Void)?) async throws -> [Page] {
        try await withThrowingTaskGroup(of: PreparedPackage?.self) { group in
            if let request = queue.next() {
                group.addTask { @MainActor in
                    try await prepare(request, queue: queue, configuration: configuration, catalog: catalog)
                }
            }
            var pages: [Page] = []
            while let outcome = try await group.next() {
                try Task.checkCancellation()
                // 网络槽与归档分开；成功额度仍在准备完成时串行计数，最多八个包。
                if let request = queue.next() {
                    group.addTask { @MainActor in
                        try await prepare(request, queue: queue, configuration: configuration, catalog: catalog)
                    }
                }
                guard let package = outcome else { continue }
                var targets = package.request.targets
                while !targets.isEmpty {
                    try Task.checkCancellation()
                    let preferred = queue.preferredPlacement()
                    let index = targets.firstIndex { $0.placement == preferred } ?? 0
                    let target = targets.remove(at: index)
                    let page = Page(placement: target.placement, document: package.document,
                                    presentation: target.presentation, resource: package.resource)
                    try await onPage?(page)
                    pages.append(page)
                }
            }
            return pages
        }
    }

    /// 下载错误只跳过关联包，取消与交付错误继续终止当前批次。
    @MainActor
    private static func prepare(_ request: PackageRequest, queue: DownloadQueue,
                                configuration: PaywallQueryConfiguration,
                                catalog: PaywallCatalog) async throws -> PreparedPackage? {
        defer { queue.inFlight -= 1 }
        do {
            let package = try await PaywallQueryRetry.run(environment: configuration.runtimeEnvironment.rawValue, stage: "package") {
                try await configuration.waitUntilNetworkAvailable?()
                return try await WebPaywallPackageLoader.prepare(
                    pageURL: request.url, runtimeEnvironment: configuration.runtimeEnvironment.rawValue,
                    allowedOrigins: configuration.allowedOrigins, catalog: catalog,
                    developmentHTTPOrigin: configuration.developmentHTTPOrigin)
            }
            try Task.checkCancellation()
            queue.completed += 1
            return PreparedPackage(request: request, document: package.0, resource: package.1)
        } catch is CancellationError { throw CancellationError() }
        catch {
            queue.failures += 1
            try Task.checkCancellation()
            for target in request.targets {
                WebPaywallDiagnostics.log(configuration.runtimeEnvironment.rawValue,
                    "query.page_skipped", "placement=\(target.placement) error=\(error)")
            }
            return nil
        }
    }

    /// 按首次出现顺序合并相同 URL，保留点位去重及各自展示方式。
    private static func packageRequests(_ positions: [Position], configuration: PaywallQueryConfiguration)
        -> (packages: [PackageRequest], unmatched: Set<String>) {
        var packages: [PackageRequest] = []
        var indices: [URL: Int] = [:]
        var unmatched: Set<String> = []
        var seen: Set<String> = []
        for position in positions {
            guard let placement = configuration.placements[position.positionKey],
                  seen.insert(placement).inserted else { continue }
            if !position.matched { unmatched.insert(placement); continue }
            guard let address = position.h5Url, let url = URL(string: address) else { continue }
            let presentation = position.displayModeKey
                .flatMap(WebPaywallConfiguration.Presentation.init(rawValue:)) ?? .fullScreen
            // 一个包下载完成时，其后的同 URL 点位也立即获得独立提交机会。
            if let index = indices[url] {
                packages[index].targets.append((placement, presentation))
            } else {
                indices[url] = packages.count
                packages.append(PackageRequest(url: url, targets: [(placement, presentation)]))
            }
        }
        // 有效响应是本轮完整点位集合；未返回的点位撤销下次启动缓存。
        // 已返回但地址无效或下载失败仍保留旧缓存，本次启动快照由运行时保持不变。
        unmatched.formUnion(Set(configuration.placements.values).subtracting(seen))
        return (packages, unmatched)
    }

    /// 兼容通用配置适配入口，查询运行时直接消费独立点位批次。
    @MainActor
    static func transform(_ bytes: Data, configuration: PaywallQueryConfiguration,
                          catalog: PaywallCatalog) async throws -> Data {
        let batch = try await load(bytes, configuration: configuration, catalog: catalog)
        var placements: [String: String] = [:]
        var presentations: [String: String] = [:]
        var paywalls: [String: [String: Any]] = [:]
        for page in batch.pages {
            let document = page.document
            if let existing = paywalls[document.documentId], existing["pageUrl"] as? String != document.pageURL.absoluteString {
                continue
            }
            placements[page.placement] = document.documentId
            presentations[page.placement] = page.presentation.rawValue
            paywalls[document.documentId] = payload(document)
        }
        return try configurationData(placements: placements, presentations: presentations, paywalls: paywalls)
    }

    /// 单点位配置独立序列化，允许同文档在不同点位绑定不同版本或发布地址。
    static func configurationData(placement: String, document: WebPaywallDocument,
                                  presentation: WebPaywallConfiguration.Presentation) throws -> Data {
        try configurationData(placements: [placement: document.documentId],
            presentations: [placement: presentation.rawValue], paywalls: [document.documentId: payload(document)])
    }

    /// 所有持久化配置继续使用现有校验协议，不缓存任何动态商品报价。
    private static func configurationData(placements: [String: String], presentations: [String: String],
                                          paywalls: [String: [String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 1, "placements": placements,
            "presentations": presentations, "paywalls": paywalls, "preload": [], "sessions": [:]], options: .sortedKeys)
    }

    /// 商品与版本来自完整包清单，接口中的展示字段不得伪造交易绑定。
    private static func payload(_ document: WebPaywallDocument) -> [String: Any] {
        ["kind": "web-paywall", "bridgeVersion": 2, "documentId": document.documentId,
         "revision": document.revision ?? 0, "pageUrl": document.pageURL.absoluteString,
         "catalogKey": document.catalogKey, "productRefs": document.productRefs,
         "initialProductRef": document.initialProductRef]
    }
}
