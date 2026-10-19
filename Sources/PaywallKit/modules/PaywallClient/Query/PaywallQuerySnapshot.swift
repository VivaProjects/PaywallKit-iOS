import Foundation

/// 按点位保存完整发布身份及原始请求，不持久化价格、权益或交易会话。
struct PaywallQuerySnapshot: Codable {
    let placement: String
    let requestIdentity: String
    let requestBody: Data
    let configuration: Data
    let identity: WebPaywallPackage.Document

    /// 资源按完整发布身份隔离，同文档不同版本或发布地址不得互相覆盖。
    var packageKey: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return WebPaywallPackage.digest((try? encoder.encode(identity)) ?? Data())
    }

    /// 重新应用当前来源、环境与商品目录，并将已校验资源绑定到本地点位。
    @MainActor
    func resolve(using query: PaywallQueryConfiguration, catalog: PaywallCatalog,
                 clientID: UUID, lease: WebPaywallResourceLease) throws -> PaywallPlacement {
        var request = URLRequest(url: query.endpoint)
        request.httpMethod = "POST"
        request.httpBody = requestBody
        guard query.placements.values.contains(placement),
              requestIdentity == PaywallQueryRequest.identity(request, namespace: query.cacheScope) else {
            throw WebPaywallError.invalidDocument
        }
        // 元数据仍按远端来源校验，本地路径只来自仓库持有的完整包租约。
        let value = try WebPaywallConfiguration(data: configuration, allowedOrigins: query.allowedOrigins,
                                               catalogs: ["default": catalog],
                                               developmentHTTPOrigin: query.developmentHTTPOrigin)
        guard !value.disabledPlacements.contains(placement),
              let remote = value.document(forPlacement: placement),
              let mode = value.presentations[placement],
              try WebPaywallPackage.identity(remote) == identity else { throw WebPaywallError.invalidDocument }
        let local = try WebPaywallDocument(packageDirectory: lease.readAccessURL, identity: identity,
                                          environment: query.runtimeEnvironment.rawValue, catalog: catalog)
        var selected = PaywallPlacement(name: placement, document: local, presentation: mode,
                                        sessionPolicy: value.sessions[placement], clientID: clientID)
        selected.historySnapshot = PaywallHistorySnapshot(namespace: query.cacheScope,
            requestURL: requestIdentity, environment: query.runtimeEnvironment.rawValue, configuration: configuration)
        selected.remoteDocument = remote
        selected.resourceLease = lease
        return selected
    }
}
