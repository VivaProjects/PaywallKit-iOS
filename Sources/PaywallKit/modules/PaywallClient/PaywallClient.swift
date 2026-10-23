import Foundation

/// 高层入口统一管理已校验配置与各点位的网页缓存；购买与资格仍由宿主提供。
@MainActor
public final class PaywallClient {
    private struct CachedPage {
        let identity: AnyHashable
        let custom: [String: WebPaywallJSONValue]
        let cache: WebPaywallWebViewCache
    }

    let id = UUID()
    private var localPackages: PaywallLocalPackageStore?
    private var previousVersionPlacements: Set<String> = []
    private let history = PaywallHistoryStore.shared

    /// 宿主注册通用本地包策略，普通 resolve/preload 继续保留原语义。
    public func useLocalPackages(_ store: PaywallLocalPackageStore,
                                 previousVersionPlacements: Set<String> = []) {
        localPackages = store
        self.previousVersionPlacements = previousVersionPlacements.intersection(store.fallbackPlacements)
    }

    /// 仅显式开启的点位保存完整成功页面，取消不会覆盖历史。
    func recordSuccess(_ selected: PaywallPlacement, document: WebPaywallDocument, environment: String) async {
        guard previousVersionPlacements.contains(selected.name),
              let snapshot = selected.historySnapshot, snapshot.environment == environment,
              !isPlacementDisabled(selected.name) else { return }
        let remote = selected.remoteDocument ?? selected.document
        guard let configured = try? WebPaywallPackage.identity(remote),
              document.productRefs == selected.document.productRefs,
              document.documentId == remote.documentId, document.revision == remote.revision else { return }
        if document.localReadAccessURL == nil {
            guard let rendered = try? WebPaywallPackage.identity(document), rendered == configured else { return }
        }
        // 本地查询快照仍按原请求及远端文档归档，不能把 file URL 当成发布身份。
        do {
            try await history.record(snapshot, placement: selected.name, document: remote,
                                     packageDirectory: document.localReadAccessURL)
        } catch is CancellationError { return }
        catch { WebPaywallDiagnostics.log(environment, "history.record_failed", "placement=\(selected.name)") }
    }

    /// 历史只使用当前已解析文档的身份，缺少目标信息时不跨页面猜测。
    func previousPlacement(_ selected: PaywallPlacement) async throws -> (PaywallPlacement, WebPaywallResourceLease)? {
        guard let snapshot = selected.historySnapshot,
              let candidate = try await history.previous(snapshot, placement: selected.name,
                                                         document: selected.document) else { return nil }
        try Task.checkCancellation()
        guard !isPlacementDisabled(selected.name) else { throw PaywallFailure.disabled }
        return (try source.historyPlacement(candidate, placement: selected.name, clientID: id), candidate.lease)
    }

    /// 任一有效配置明确关闭点位时不得兜底，重开需刷新对应配置。
    func isPlacementDisabled(_ placement: String) -> Bool {
        localPackages?.isDisabled(placement) == true
            || cachedConfiguration?.disabledPlacements.contains(placement) == true
    }

    /// 仅受支持的主动点位共享兜底上下文。
    func makeFallbackContext(_ placement: String) -> PaywallFallbackContext {
        let store = localPackages.flatMap {
            $0.placement == placement || $0.fallbackPlacements.contains(placement) ? $0 : nil
        }
        return PaywallFallbackContext(placement: placement, store: store,
            usesPreviousVersion: previousVersionPlacements.contains(placement),
            startsLocally: queryRuntime?.cachedPlacement(placement) == nil,
            cachedFallback: queryRuntime?.fallbackAtLaunch)
    }

    /// 可见展示优先排队下载，普通预加载不改变优先级。
    func prioritizePresentation(_ placement: String) {
        queryRuntime?.prioritize(placement)
    }

    /// 查询模式展示最多等待三秒，超时沿用本地兜底；共享后台更新继续运行。
    func resolveForPresentation(_ placement: String, context: PaywallFallbackContext) async throws -> PaywallPlacement {
        if isPlacementDisabled(placement) { throw PaywallFailure.disabled }
        if context.local { return try context.localPlacement(clientID: id) }
        do {
            // 仅展示等待有期限，普通预加载仍等待共享查询完成。
            guard var selected = try await resolveForEntry(placement) else { throw PaywallFailure.missingPlacement }
            try Task.checkCancellation()
            // 配置等待不消耗商品与网页的准备期限，本次容器仍沿用打开时冻结的形态。
            context.beginPreparation()
            context.capture(selected)
            context.record(selected.document)
            selected.fallbackContext = context
            return selected
        } catch is CancellationError { throw CancellationError() }
        catch {
            let failure = error as? PaywallFailure ?? .configuration
            guard let fallback = try await context.advance(failure, client: self) else { throw failure }
            return fallback
        }
    }

    /// 可见入口统一限制查询等待；没有本地兜底的点位仍按原策略跳过或报错。
    func resolveForEntry(_ placement: String) async throws -> PaywallPlacement? {
        guard !isPlacementDisabled(placement) else { return nil }
        if let queryRuntime { return try await queryRuntime.resolve(placement, presentation: true) }
        return try await resolve(placement)
    }

    private var queryRuntime: PaywallQueryRuntime?
    private let source: PaywallConfigurationSource
    private let retainedPlacements: Set<String>
    private var cachedConfiguration: WebPaywallConfiguration?
    private var configurationGeneration = UUID()
    private var configurationTask: Task<WebPaywallConfiguration, Error>?
    private var pages: [String: [CachedPage]] = [:]

    var hasConfiguration: Bool { queryRuntime?.hasConfiguration ?? (cachedConfiguration != nil) }

    public init(configuration: PaywallConfigurationSource, retainedPlacements: Set<String> = []) {
        source = configuration
        self.retainedPlacements = retainedPlacements
    }

    /// 查询接口入口内置设备条件、归因等待、响应转换及包更新，保留原 GET 接入。
    public convenience init(query: PaywallQueryConfiguration, catalog: @escaping () -> PaywallCatalog,
                            retainedPlacements: Set<String> = []) {
        PaywallCacheMaintenance.prepareQueryClient()
        let runtime = PaywallQueryRuntime(configuration: query, catalog: catalog)
        self.init(configuration: runtime.source(), retainedPlacements: retainedPlacements)
        queryRuntime = runtime
        runtime.attach(to: self)
    }

    /// 将任意归因 SDK 的结果交给查询入口；失败时保留已知渠道或使用 organic。
    public func reportAttribution(channel: String?, failed: Bool = false) {
        queryRuntime?.reportAttribution(channel: channel, failed: failed)
    }

    /// 宿主可将此版本用于预加载身份，不需要了解渠道或配置缓存内部状态。
    public var configurationRevision: UUID { configurationGeneration }

    /// 接入方只配置接口地址与条件，SDK 自动采集默认值并构造 GET 请求。
    public convenience init(endpoint: String, parameters: PaywallRequestParameters = .init(),
                            cacheNamespace: String, allowedOrigins: Set<String>?,
                            developmentHTTPOrigin: String? = nil,
                            configurationEnabled: Bool = true,
                            catalogs: @escaping () -> [String: PaywallCatalog],
                            retainedPlacements: Set<String> = []) {
        let source = PaywallConfigurationSource(
            cacheNamespace: cacheNamespace, allowedOrigins: allowedOrigins,
            developmentHTTPOrigin: developmentHTTPOrigin, catalogs: catalogs,
            request: {
                guard configurationEnabled else { throw WebPaywallError.invalidDocument }
                return try await parameters.request(endpoint: endpoint)
            }
        )
        self.init(configuration: source, retainedPlacements: retainedPlacements)
    }

    /// 查询入口先恢复点位缓存再静默更新；无缓存时继续等待唯一查询。
    public func prepare() async throws {
        if let queryRuntime { try await queryRuntime.prepare(); return }
        _ = try await configuration()
    }

    /// 自定义来源可主动刷新；查询入口始终复用首次成功或失败结果。
    public func refresh() async throws {
        if let queryRuntime { try await queryRuntime.prepare(); return }
        if queryRuntime == nil, configurationTask == nil { cachedConfiguration = nil }
        _ = try await configuration()
    }

    /// 仅自定义来源允许失效；查询入口的首次条件与结果保持到 Client 释放。
    public func invalidateConfiguration() {
        guard queryRuntime == nil else { return }
        configurationGeneration = UUID()
        configurationTask?.cancel()
        configurationTask = nil
        cachedConfiguration = nil
    }

    /// 一次返回点位的页面与展示方式；缺失点位交给调用方决定跳过或报错。
    public func resolve(_ placement: String) async throws -> PaywallPlacement? {
        if let queryRuntime {
            guard !isPlacementDisabled(placement) else { throw PaywallFailure.disabled }
            return try await queryRuntime.resolve(placement)
        }
        let configuration = try await configuration()
        try Task.checkCancellation()
        if configuration.disabledPlacements.contains(placement) || localPackages?.isDisabled(placement) == true { throw PaywallFailure.disabled }
        return resolved(placement, configuration: configuration)
    }

    /// 已缓存配置可同步解析，重复打开不先展示配置加载界面。
    public func cachedPlacement(_ placement: String) -> PaywallPlacement? {
        if let queryRuntime {
            return isPlacementDisabled(placement) ? nil : queryRuntime.cachedPlacement(placement)
        }
        guard let cachedConfiguration, !isPlacementDisabled(placement) else { return nil }
        return resolved(placement, configuration: cachedConfiguration)
    }

    /// 显式重试或业务目录失效时释放旧页，已挂载页面由底层在卸载时销毁。
    public func invalidatePage(for placement: String) {
        pages.removeValue(forKey: placement)?.forEach { $0.cache.destroy() }
    }

    /// 按业务身份和 custom 分别保留入口网页，避免同一点位的不同展示参数相互清除。
    func pageCache(for placement: String, identity: AnyHashable,
                   custom: [String: WebPaywallJSONValue]) -> WebPaywallWebViewCache? {
        guard retainedPlacements.contains(placement) else { return nil }
        // 商品、价格或权益变化时整体失效，不能保留其他入口的旧交易页面。
        if let first = pages[placement]?.first, first.identity != identity {
            invalidatePage(for: placement)
        }
        var variants = pages[placement] ?? []
        if let index = variants.firstIndex(where: { $0.custom == custom }) {
            let entry = variants.remove(at: index)
            variants.append(entry)
            pages[placement] = variants
            return entry.cache
        }
        // 每个点位最多保留四种上下文；被淘汰的挂载页仍按原规则延迟销毁。
        if variants.count >= 4 { variants.removeFirst().cache.destroy() }
        let cache = WebPaywallWebViewCache(retentionPolicy: .keepAfterDismissal)
        variants.append(CachedPage(identity: identity, custom: custom, cache: cache))
        pages[placement] = variants
        return cache
    }

    /// 同步读取当前实际页面的就绪缓存，本地包与远端页均重建当前入口的交易输入。
    func preparedCachedPage(for placement: String, identity: AnyHashable,
                            resolved: PaywallPlacement?,
                            prepare: (WebPaywallDocument) throws -> PaywallSessionInput) -> PaywallPreparedPage? {
        guard !isPlacementDisabled(placement), let variants = pages[placement],
              variants.first?.identity == identity else { return nil }
        // 优先使用宿主已冻结的版本；无宿主时本地点位直接读取本地包，不依赖远端配置。
        let context = makeFallbackContext(placement)
        let selected: PaywallPlacement?
        if let resolved, resolved.name == placement, resolved.clientID == id {
            selected = resolved
        } else if context.local {
            selected = try? context.localPlacement(clientID: id)
        } else {
            selected = cachedPlacement(placement)
        }
        guard let selected, let input = try? prepare(selected.document),
              let entry = variants.first(where: { $0.custom == input.custom }) else { return nil }
        // 环境、custom、商品绑定和首屏回执仍由底层精确核对。
        let page = PaywallPreparedPage(placement: selected, input: input, cache: entry.cache)
        WebPaywallDiagnostics.log(input.environment.runtimeEnvironment.rawValue, "cache.readiness",
                                  "placement=\(placement) ready=\(page.isReady)")
        return page.isReady ? page : nil
    }

    /// 独立任务不随单个页面关闭而取消；查询入口的失败立即交给已有兜底。
    private func configuration() async throws -> WebPaywallConfiguration {
        while true {
            try Task.checkCancellation()
            let generation = configurationGeneration
            if let cachedConfiguration { return cachedConfiguration }
            do {
                if let configurationTask { return try await configurationTask.value }
                return try await loadConfiguration()
            } catch is CancellationError {
                // 宿主改变渠道只取消旧请求，不取消仍在等待展示的新会话。
                try Task.checkCancellation()
                guard generation != configurationGeneration else { throw CancellationError() }
            }
        }
    }

    /// 查询入口保留首次任务的成功或失败结果，后续入口不得再次访问配置接口。
    private func loadConfiguration() async throws -> WebPaywallConfiguration {
        let generation = configurationGeneration
        let task = Task { [self] in
            // 查询失败也保留任务结果；普通自定义来源仍允许主动重试。
            defer {
                if queryRuntime == nil, generation == configurationGeneration { configurationTask = nil }
            }
            let value = try await source.load()
            try Task.checkCancellation()
            guard generation == configurationGeneration else { throw CancellationError() }
            cachedConfiguration = value
            return value
        }
        configurationTask = task
        return try await task.value
    }

    /// 只从完整校验后的配置构造不可变点位快照。
    private func resolved(_ placement: String, configuration: WebPaywallConfiguration) -> PaywallPlacement? {
        guard let document = configuration.document(forPlacement: placement),
              let presentation = configuration.presentations[placement] else { return nil }
        return PaywallPlacement(name: placement, document: document,
                                presentation: presentation, sessionPolicy: configuration.sessions[placement], clientID: id,
                                historySnapshot: configuration.historySnapshot)
    }
}
