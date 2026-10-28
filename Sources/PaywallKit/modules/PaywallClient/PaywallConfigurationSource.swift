import Foundation

/// 配置来源仅描述宿主的请求与信任边界，网络、本地副本和校验由 SDK 执行。
@MainActor
public struct PaywallConfigurationSource {
    private let request: () async throws -> URLRequest
    private let responseTransform: (Data) async throws -> Data
    private let requestIdentity: (URLRequest) -> String
    private let runtimeEnvironment: String?
    var diagnosticEnvironment: String? { runtimeEnvironment }
    private let isCurrentRequest: (URLRequest) -> Bool
    private let namespace: String
    private let allowedOrigins: Set<String>?
    private let catalogs: () -> [String: PaywallCatalog]
    private let developmentHTTPOrigin: String?
    private let defaults: UserDefaults
    private let legacyCacheKey: (URLRequest) -> String?

    /// 宿主可转换业务响应并提供 POST 请求身份，默认保持原 GET 协议。
    public init(cacheNamespace: String, allowedOrigins: Set<String>?,
                developmentHTTPOrigin: String? = nil,
                defaults: UserDefaults = .standard,
                legacyCacheKey: @escaping (URLRequest) -> String? = { _ in nil },
                catalogs: @escaping () -> [String: PaywallCatalog],
                runtimeEnvironment: String? = nil,
                requestIdentity: @escaping (URLRequest) -> String = { $0.url?.absoluteString ?? "" },
                isCurrentRequest: @escaping (URLRequest) -> Bool = { _ in true },
                responseTransform: @escaping (Data) async throws -> Data = { $0 },
                request: @escaping () async throws -> URLRequest) {
        namespace = cacheNamespace
        self.allowedOrigins = allowedOrigins
        self.developmentHTTPOrigin = developmentHTTPOrigin
        self.defaults = defaults
        self.legacyCacheKey = legacyCacheKey
        self.catalogs = catalogs
        self.request = request
        self.responseTransform = responseTransform
        self.requestIdentity = requestIdentity
        self.runtimeEnvironment = runtimeEnvironment
        self.isCurrentRequest = isCurrentRequest
    }

    /// 有效响应才覆盖本地缓存；网络失败时只读取相同请求身份的有效副本。
    func load() async throws -> WebPaywallConfiguration {
        let request = try await request()
        guard let url = request.url else { throw WebPaywallError.invalidDocument }
        let environment = runtimeEnvironment ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "runtimeEnvironment" })?.value ?? ""
        let key = "paywall.configuration.v2.\(namespace).\(requestIdentity(request))"
        let catalogs = catalogs()
        do {
            let data = try await fetch(request, environment: environment)
            try checkCurrent(request)
            let configuration = try snapshot(data, request: request, environment: environment, catalogs: catalogs)
            // 只保存已转换且完整校验的配置，离线读取不再访问页面元数据。
            defaults.set(data, forKey: key)
            WebPaywallDiagnostics.log(environment, "configuration.loaded", "source=network")
            return configuration
        } catch {
            try checkCurrent(request)
            if error is CancellationError { throw error }
            let legacy = "paywall.configuration.v1.\(namespace).\(url.absoluteString)"
            let keys = [key] + (request.httpMethod == "GET" || request.httpMethod == nil ? [legacy] : [])
                + (legacyCacheKey(request).map { [$0] } ?? [])
            // 缓存使用当前目录与信任边界复验，POST 不读取旧的 URL-only 副本。
            for candidate in keys {
                if let data = defaults.data(forKey: candidate),
                   let configuration = try? snapshot(data, request: request, environment: environment, catalogs: catalogs) {
                    defaults.set(data, forKey: key)
                    WebPaywallDiagnostics.log(environment, "configuration.loaded", "source=cache")
                    return configuration
                }
            }
            throw error
        }
    }

    /// 查询迁移仅按已构造的确切请求读取副本，不访问网络或转换页面元数据。
    func cachedConfiguration(for request: URLRequest) throws -> WebPaywallConfiguration? {
        let key = "paywall.configuration.v2.\(namespace).\(requestIdentity(request))"
        guard let data = defaults.data(forKey: key) else { return nil }
        return try snapshot(data, request: request, environment: runtimeEnvironment ?? "", catalogs: catalogs())
    }

    /// 网络返回先完成宿主转换，业务错误和半包不会进入配置缓存。
    private func fetch(_ request: URLRequest, environment: String) async throws -> Data {
        // 原始 HTTP 返回在转换与校验之前记录，业务错误也能定位。
        let (data, response) = try await PaywallConfigurationDiagnostics.data(for: request, environment: environment)
        try checkCurrent(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_000_000 else {
            throw WebPaywallError.invalidDocument
        }
        return try await responseTransform(data)
    }

    /// 渠道变化或任务取消后，不允许旧网络结果及旧缓存覆盖新请求。
    private func checkCurrent(_ request: URLRequest) throws {
        try Task.checkCancellation()
        guard isCurrentRequest(request) else { throw CancellationError() }
    }

    /// 历史记录重新使用当前来源白名单与注册商品目录校验。
    func validateHistory(_ snapshot: PaywallHistorySnapshot) throws -> WebPaywallConfiguration {
        guard snapshot.namespace == namespace else { throw PaywallFailure.configuration }
        return try validate(snapshot.configuration, catalogs: catalogs())
    }

    /// 恢复历史配置和本地文件时，重新应用当前目录与来源校验。
    func historyPlacement(_ candidate: PaywallHistoryStore.Candidate, placement: String,
                          clientID: UUID) throws -> PaywallPlacement {
        let configuration = try validateHistory(candidate.snapshot)
        guard !configuration.disabledPlacements.contains(placement),
              let remote = configuration.document(forPlacement: placement),
              try WebPaywallPackage.identity(remote) == candidate.identity,
              let catalog = catalogs()[remote.catalogKey],
              let presentation = configuration.presentations[placement] else { throw PaywallFailure.configuration }
        // 文件已在历史仓库后台完整验证，当前来源与商品目录仍在此重新授权。
        let document = candidate.document
        guard document.productRefs.allSatisfy({ catalog.productRefs.contains($0) }) else {
            throw WebPaywallError.invalidDocument
        }
        return PaywallPlacement(name: placement, document: document, presentation: presentation,
                                sessionPolicy: configuration.sessions[placement], clientID: clientID)
    }

    /// 成功解析的配置保留原始请求身份，展示期间不会被后续刷新覆盖。
    private func snapshot(_ data: Data, request: URLRequest, environment: String,
                          catalogs: [String: PaywallCatalog]) throws -> WebPaywallConfiguration {
        var configuration = try validate(data, catalogs: catalogs)
        if ["test", "production"].contains(environment) {
            configuration.historySnapshot = PaywallHistorySnapshot(
                namespace: namespace, requestURL: requestIdentity(request),
                environment: environment, configuration: data)
        }
        return configuration
    }

    /// 所有读取路径使用同一份完整配置校验。
    private func validate(_ data: Data, catalogs: [String: PaywallCatalog]) throws -> WebPaywallConfiguration {
        try WebPaywallConfiguration(data: data, allowedOrigins: allowedOrigins,
                                    catalogs: catalogs, developmentHTTPOrigin: developmentHTTPOrigin)
    }
}
