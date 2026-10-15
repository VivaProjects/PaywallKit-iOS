import Foundation
import StoreKit
import UIKit

/// 查询接口的生命周期协调器；宿主只需准备 Client 并转交归因结果。
@MainActor
final class PaywallQueryRuntime {
    private let configuration: PaywallQueryConfiguration
    private let catalog: () -> PaywallCatalog
    private let attribution: PaywallQueryAttribution
    private weak var client: PaywallClient?
    private var activeIdentity: String?
    private var activeChannel: String?
    private var activeCountry: String?
    private var stores: [String: PaywallLocalPackageStore] = [:]
    private var currentStore: PaywallLocalPackageStore?
    private var lastRefresh: Date?
    private var refreshTask: Task<Void, Never>?
    private var refreshID = UUID()
    private var packageTask: Task<Void, Never>?
    private var storefrontTask: Task<Void, Never>?
    private var foregroundTask: Task<Void, Never>?

    /// 将平台无关的接入声明与宿主商品目录绑定。
    init(configuration: PaywallQueryConfiguration, catalog: @escaping () -> PaywallCatalog) {
        self.configuration = configuration
        self.catalog = catalog
        attribution = PaywallQueryAttribution(namespace: configuration.cacheScope)
    }

    deinit {
        refreshTask?.cancel()
        packageTask?.cancel()
        storefrontTask?.cancel()
        foregroundTask?.cancel()
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

    /// 内置包立即可用；监听不触发初始请求，首次 prepare/resolve 才开始加载。
    func attach(to client: PaywallClient) {
        self.client = client
        selectStore(identity: "bundled")
        attribution.onChange = { [weak self] in
            guard let self, let activeChannel = self.activeChannel,
                  activeChannel != self.attribution.channel else { return }
            self.invalidate()
        }
        storefrontTask = Task { [weak self] in
            for await storefront in Storefront.updates {
                guard !Task.isCancelled else { return }
                self?.storefrontChanged(storefront.countryCode)
            }
        }
        foregroundTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                guard !Task.isCancelled else { return }
                self?.refreshIfNeeded()
            }
        }
    }

    /// 归因 SDK 回调只有这一处转交，不要求宿主保存状态、等待或主动刷新。
    func reportAttribution(channel: String?, failed: Bool) {
        attribution.update(channel: channel, failed: failed)
    }

    /// 网络及离线成功加载都驱动同一更新流程，更新失败不影响内置兜底。
    func didLoad(_ value: WebPaywallConfiguration) {
        lastRefresh = Date()
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

    /// 每次请求动态采集条件，参数变化后使用独立的兜底仓库。
    private func request() async throws -> URLRequest {
        let request = try await PaywallQueryRequest.request(configuration: configuration, attribution: attribution)
        try Task.checkCancellation()
        guard let data = request.httpBody else { throw WebPaywallError.invalidDocument }
        let query = try JSONDecoder().decode(PaywallQueryRequest.self, from: data)
        guard query.channelKey == (attribution.channel ?? "organic") else { throw CancellationError() }
        let identity = PaywallQueryRequest.identity(request, namespace: configuration.cacheScope)
        if activeIdentity != identity { selectStore(identity: identity) }
        activeIdentity = identity
        activeChannel = query.channelKey
        activeCountry = query.conditions.country
        return request
    }

    /// 请求身份与当前归因必须同时匹配，防止旧响应或旧缓存重新生效。
    private func isCurrent(_ request: URLRequest) -> Bool {
        activeIdentity == PaywallQueryRequest.identity(request, namespace: configuration.cacheScope)
            && activeChannel == (attribution.channel ?? "organic")
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

    /// 商店变更由 SDK 自己监听，不需要修改宿主订阅服务。
    private func storefrontChanged(_ country: String) {
        guard let activeCountry, activeCountry != PaywallQueryCountryCode.alpha2(country) else { return }
        invalidate()
    }

    /// 只使后续解析失效，不销毁已经展示的页面；旧下载不得更新当前兜底。
    private func invalidate() {
        guard activeIdentity != nil else { return }
        packageTask?.cancel()
        refreshTask?.cancel()
        client?.invalidateConfiguration()
        activeIdentity = nil
        activeChannel = nil
        activeCountry = nil
        selectStore(identity: "bundled")
        scheduleRefresh()
    }

    /// 前台恢复最多每小时查询一次，多个入口继续共享 Client 的请求任务。
    private func refreshIfNeeded() {
        guard lastRefresh.map({ Date().timeIntervalSince($0) >= 3600 }) ?? true else { return }
        guard refreshTask == nil else { return }
        scheduleRefresh()
    }

    /// 刷新任务有明确所有权；过期任务不能清理新的任务引用。
    private func scheduleRefresh() {
        let token = UUID()
        refreshID = token
        lastRefresh = Date()
        refreshTask = Task { [weak self] in
            guard let client = self?.client else { return }
            defer { if self?.refreshID == token { self?.refreshTask = nil } }
            do { try await client.refresh() }
            catch is CancellationError { return }
            catch {
                guard let self else { return }
                WebPaywallDiagnostics.log(self.configuration.runtimeEnvironment.rawValue,
                                          "configuration.refresh_failed", "code=\((error as NSError).code)")
            }
        }
    }
}
