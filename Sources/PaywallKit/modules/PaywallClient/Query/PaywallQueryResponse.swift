import Foundation

/// 服务端只下发点位与页面地址；商品目录与版本必须来自对应完整页面包。
struct PaywallQueryResponse: Decodable {
    struct Position: Decodable {
        let positionKey: String
        let matched: Bool
        let h5Url: String?
        let displayModeKey: String?
    }
    let code: String
    let data: [Position]?

    /// 逐页完成包与商品校验，全部成功后再交给 SDK 原子更新配置。
    @MainActor
    static func transform(_ bytes: Data, configuration: PaywallQueryConfiguration,
                          catalog: PaywallCatalog) async throws -> Data {
        let response = try JSONDecoder().decode(Self.self, from: bytes)
        guard response.code == "200", let positions = response.data, !positions.isEmpty, positions.count <= 100 else {
            throw WebPaywallError.invalidDocument
        }
        var placements: [String: String] = [:]
        var presentations: [String: String] = [:]
        var paywalls: [String: [String: Any]] = [:]
        var loaded: [URL: WebPaywallDocument] = [:]
        for position in positions where position.matched {
            guard let placement = configuration.placements[position.positionKey] else { continue }
            guard placements[placement] == nil,
                  let address = position.h5Url, let url = URL(string: address),
                  let mode = position.displayModeKey,
                  WebPaywallConfiguration.Presentation(rawValue: mode) != nil else {
                throw WebPaywallError.invalidDocument
            }
            let document: WebPaywallDocument
            if let existing = loaded[url] { document = existing }
            else {
                document = try await WebPaywallPackageLoader.load(
                    pageURL: url, runtimeEnvironment: configuration.runtimeEnvironment.rawValue,
                    allowedOrigins: configuration.allowedOrigins,
                    catalog: catalog, developmentHTTPOrigin: configuration.developmentHTTPOrigin)
                loaded[url] = document
            }
            try Task.checkCancellation()
            if let existing = paywalls[document.documentId], existing["pageUrl"] as? String != document.pageURL.absoluteString {
                throw WebPaywallError.invalidDocument
            }
            placements[placement] = document.documentId
            presentations[placement] = mode
            paywalls[document.documentId] = payload(document)
        }
        return try JSONSerialization.data(withJSONObject: [
            "version": 1, "placements": placements, "presentations": presentations,
            "paywalls": paywalls, "preload": [], "sessions": [:]
        ], options: .sortedKeys)
    }

    /// 将经过完整包校验的文档转换为 SDK 通用清单，不使用接口中的空商品字段。
    private static func payload(_ document: WebPaywallDocument) -> [String: Any] {
        ["kind": "web-paywall", "bridgeVersion": 2, "documentId": document.documentId,
         "revision": document.revision ?? 0, "pageUrl": document.pageURL.absoluteString,
         "catalogKey": document.catalogKey, "productRefs": document.productRefs,
         "initialProductRef": document.initialProductRef]
    }
}
