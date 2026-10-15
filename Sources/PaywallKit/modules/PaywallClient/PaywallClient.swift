import Foundation

/// 高层入口统一管理已校验配置与各点位的网页缓存；购买与资格仍由宿主提供。
@MainActor
public final class PaywallClient {
    private struct CachedPage {
        let identity: AnyHashable
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
              selected.document.localReadAccessURL == nil, !isPlacementDisabled(selected.name),
              let rendered = try? WebPaywallPackage.identity(document),
              let configured = try? WebPaywallPackage.identity(selected.document), rendered == configured else { return }
        do {
            try await history.record(snapshot, placement: selected.name, document: selected.document)
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
                                      usesPreviousVersion: previousVersionPlacements.contains(placement))
    }

    /// 展示解析覆盖配置阶段超时；本地入口完全绕过远端请求。
    func resolveForPresentation(_ placement: String, context: PaywallFallbackContext) async throws -> PaywallPlacement {
        if isPlacementDisabled(placement) { throw PaywallFailure.disabled }
        if context.local { return try context.localPlacement(clientID: id) }
        do {
            let selected = try await PaywallDeadline<PaywallPlacement?>().run(until: context.deadline) {
                try await self.resolve(placement)
            }
            guard var selected else { throw PaywallFailure.missingPlacement }
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

    private var queryRuntime: PaywallQueryRuntime?
    private let source: PaywallConfigurationSource
    private let retainedPlacements: Set<String>
    private var cachedConfiguration: WebPaywallConfiguration?
    private var configurationGeneration = UUID()
    private var configurationTask: Task<WebPaywallConfiguration, Error>?
    private var pages: [String: CachedPage] = [:]

    var hasConfiguration: Bool { cachedConfiguration != nil }

    public init(configuration: PaywallConfigurationSource, retainedPlacements: Set<String> = []) {
        source = configuration
        self.retainedPlacements = retainedPlacements
    }

    /// 查询接口入口内置设备条件、归因等待、响应转换及包更新，保留原 GET 接入。
    public convenience init(query: PaywallQueryConfiguration, catalog: @escaping () -> PaywallCatalog,
                            retainedPlacements: Set<String> = []) {
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

    /// 启动预取与展示入口共享请求；成功冻结到当前 Client，失败允许下一次主动重试。
    public func prepare() async throws {
        _ = try await configuration()
    }

    /// 后台更新后刷新配置开关，不改变已冻结的展示输入。
    public func refresh() async throws {
        if configurationTask == nil { cachedConfiguration = nil }
        _ = try await configuration()
    }

    /// 使后续解析重新读取请求条件；已展示页面仍持有自己的不可变快照。
    public func invalidateConfiguration() {
        configurationGeneration = UUID()
        configurationTask?.cancel()
        configurationTask = nil
        cachedConfiguration = nil
    }

    /// 一次返回点位的页面与展示方式；缺失点位交给调用方决定跳过或报错。
    public func resolve(_ placement: String) async throws -> PaywallPlacement? {
        let configuration = try await configuration()
        try Task.checkCancellation()
        if configuration.disabledPlacements.contains(placement) || localPackages?.isDisabled(placement) == true { throw PaywallFailure.disabled }
        return resolved(placement, configuration: configuration)
    }

    /// 已缓存配置可同步解析，重复打开不先展示配置加载界面。
    public func cachedPlacement(_ placement: String) -> PaywallPlacement? {
        guard let cachedConfiguration, !isPlacementDisabled(placement) else { return nil }
        return resolved(placement, configuration: cachedConfiguration)
    }

    /// 显式重试或业务目录失效时释放旧页，已挂载页面由底层在卸载时销毁。
    public func invalidatePage(for placement: String) {
        pages.removeValue(forKey: placement)?.cache.destroy()
    }

    /// 按宿主提供的商品/价格/权益身份复用网页，页面版本再由底层缓存键核对。
    func pageCache(for placement: String, identity: AnyHashable) -> WebPaywallWebViewCache? {
        guard retainedPlacements.contains(placement) else { return nil }
        if let entry = pages[placement], entry.identity == identity { return entry.cache }
        invalidatePage(for: placement)
        let cache = WebPaywallWebViewCache(retentionPolicy: .keepAfterDismissal)
        pages[placement] = CachedPage(identity: identity, cache: cache)
        return cache
    }

    /// 同步读取当前实际页面的就绪缓存，本地包与远端页均重建当前入口的交易输入。
    func preparedCachedPage(for placement: String, identity: AnyHashable,
                            resolved: PaywallPlacement?,
                            prepare: (WebPaywallDocument) throws -> PaywallSessionInput) -> PaywallPreparedPage? {
        guard !isPlacementDisabled(placement), let entry = pages[placement],
              entry.identity == identity else { return nil }
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
        guard let selected, let input = try? prepare(selected.document) else { return nil }
        // 环境、custom、商品绑定和首屏回执仍由底层精确核对。
        let page = PaywallPreparedPage(placement: selected, input: input, cache: entry.cache)
        WebPaywallDiagnostics.log(input.environment.runtimeEnvironment.rawValue, "cache.readiness",
                                  "placement=\(placement) ready=\(page.isReady)")
        return page.isReady ? page : nil
    }

    /// 独立共享任务不随单个页面关闭而取消，失败任务及时移除，避免重试永久复用错误。
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

    /// 合并预取与刷新请求，并阻止过期任务清理新任务或写回旧配置。
    private func loadConfiguration() async throws -> WebPaywallConfiguration {
        let generation = configurationGeneration
        let task = Task { [self] in
            defer { if generation == configurationGeneration { configurationTask = nil } }
            let value = try await source.load()
            try Task.checkCancellation()
            guard generation == configurationGeneration else { throw CancellationError() }
            cachedConfiguration = value
            queryRuntime?.didLoad(value)
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
