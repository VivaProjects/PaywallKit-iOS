import Foundation

/// 查询接口只采集一次请求条件，首次结果由 Client 在整个生命周期内复用。
@MainActor
final class PaywallQueryRuntime {
    private let configuration: PaywallQueryConfiguration
    private let catalog: () -> PaywallCatalog
    private let attribution: PaywallQueryAttribution
    private weak var client: PaywallClient?
    private var activeIdentity: String?
    private var stores: [String: PaywallLocalPackageStore] = [:]
    private var currentStore: PaywallLocalPackageStore?
    private var packageTask: Task<Void, Never>?

    /// 将平台无关的接入声明与宿主商品目录绑定。
    init(configuration: PaywallQueryConfiguration, catalog: @escaping () -> PaywallCatalog) {
        self.configuration = configuration
        self.catalog = catalog
        attribution = PaywallQueryAttribution(namespace: configuration.cacheScope)
    }

    deinit {
        packageTask?.cancel()
    }

    /// 配置来源复用通用网络与持久缓存，不向宿主暴露 JSON 转换细节。
    func source() -> PaywallConfigurationSource {
        PaywallConfigurationSource(
            cacheNamespace: configuration.cacheScope, allowedOrigins: configuration.allowedOrigins,
            developmentHTTPOrigin: configuration.developmentHTTPOrigin,
            catalogs: { ["default": self.catalog()] },
            runtimeEnvironment: configuration.runtimeEnvironment.rawValue,
            requestIdentity: { PaywallQueryRequest.identity($0, namespace: self.configuration.cacheScope) },
            isCurrentRequest: { self.isCurrent($0) },
            responseTransform: { try await PaywallQueryResponse.transform($0, configuration: self.configuration, catalog: self.catalog()) },
            request: { try await self.request() })
    }

    /// 内置包立即可用；首次 prepare/resolve 才加载，前台及商店变化不再触发查询。
    func attach(to client: PaywallClient) {
        self.client = client
        selectStore(identity: "bundled")
    }

    /// 首次查询使用已知归因；迟到回调只保存归因，供下次 App 启动使用。
    func reportAttribution(channel: String?, failed: Bool) {
        attribution.update(channel: channel, failed: failed)
    }

    /// 网络及离线成功加载都驱动同一更新流程，更新失败不影响内置兜底。
    func didLoad(_ value: WebPaywallConfiguration) {
        guard let fallback = configuration.fallback, let store = currentStore,
              let document = value.document(forPlacement: fallback.placement) else { return }
        packageTask?.cancel()
        let environment = configuration.runtimeEnvironment.rawValue
        packageTask = Task {
            do { try await store.adopt(document) }
            catch is CancellationError { return }
            catch { WebPaywallDiagnostics.log(environment, "local_package.update_failed", "code=\((error as NSError).code)") }
        }
    }

    /// 首次查询冻结条件，并选择相同请求身份的本地兜底仓库。
    private func request() async throws -> URLRequest {
        let request = try await PaywallQueryRequest.request(configuration: configuration, attribution: attribution)
        try Task.checkCancellation()
        // 条件由首次请求冻结；后续归因变化不会使本次响应失效。
        guard request.httpBody != nil else { throw WebPaywallError.invalidDocument }
        let identity = PaywallQueryRequest.identity(request, namespace: configuration.cacheScope)
        if activeIdentity != identity { selectStore(identity: identity) }
        activeIdentity = identity
        return request
    }

    /// 只校验首次冻结的请求身份，迟到归因不得废弃唯一一次查询及其缓存。
    private func isCurrent(_ request: URLRequest) -> Bool {
        activeIdentity == PaywallQueryRequest.identity(request, namespace: configuration.cacheScope)
    }

    /// 同一进程复用各请求的仓库，不能在旧会话仍持有文件时重新初始化清理。
    private func selectStore(identity: String) {
        guard let fallback = configuration.fallback, let client else { return }
        let store: PaywallLocalPackageStore
        if let existing = stores[identity] { store = existing }
        else {
            store = PaywallLocalPackageStore(
                placement: fallback.placement, fallbackPlacements: fallback.fallbackPlacements,
                bundledDirectory: fallback.bundledDirectory,
                runtimeEnvironment: configuration.runtimeEnvironment.rawValue,
                allowedOrigins: configuration.allowedOrigins,
                developmentHTTPOrigin: configuration.developmentHTTPOrigin,
                cacheNamespace: "\(configuration.cacheScope).packages.\(identity)", catalog: catalog)
            stores[identity] = store
        }
        currentStore = store
        client.useLocalPackages(store, previousVersionPlacements: fallback.previousVersionPlacements)
    }
}
