import Foundation

/// 启动快照转换只处理宿主权限与会话绑定，资源校验由后台仓库完成。
extension PaywallQuerySnapshot {
    /// 重新应用当前来源、环境与商品目录，并将已校验资源绑定到本地点位。
    @MainActor
    func resolve(using query: PaywallQueryConfiguration, catalog: PaywallCatalog,
                 clientID: UUID, lease: WebPaywallResourceLease, localDocument: WebPaywallDocument) throws -> PaywallPlacement {
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
        // 完整资源已在后台校验；这里仍检查本地文档与远端绑定及租约完全一致。
        guard localDocument.localReadAccessURL == lease.readAccessURL,
              localDocument.pageURL == lease.pageURL, localDocument.catalogKey == identity.catalogKey,
              localDocument.documentId == identity.documentId, localDocument.revision == identity.revision,
              localDocument.productRefs == identity.productRefs,
              localDocument.initialProductRef == identity.initialProductRef,
              identity.productRefs.allSatisfy({ catalog.productRefs.contains($0) }) else {
            throw WebPaywallError.invalidDocument
        }
        let local = localDocument
        var selected = PaywallPlacement(name: placement, document: local, presentation: mode,
                                        sessionPolicy: value.sessions[placement], clientID: clientID)
        selected.historySnapshot = PaywallHistorySnapshot(namespace: query.cacheScope,
            requestURL: requestIdentity, environment: query.runtimeEnvironment.rawValue, configuration: configuration)
        selected.remoteDocument = remote
        selected.resourceLease = lease
        return selected
    }
}
