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

    /// 点位独立解析；坏页面跳过，空结果交由入口使用本地兜底。
    @MainActor
    static func transform(_ bytes: Data, configuration: PaywallQueryConfiguration,
                          catalog: PaywallCatalog) async throws -> Data {
        let response = try JSONDecoder().decode(Self.self, from: bytes)
        guard response.code == "200", let positions = response.data, positions.count <= 100 else {
            throw WebPaywallError.invalidDocument
        }
        var placements: [String: String] = [:]
        var presentations: [String: String] = [:]
        var paywalls: [String: [String: Any]] = [:]
        var loaded: [URL: WebPaywallDocument] = [:]
        for position in positions where position.matched {
            guard let placement = configuration.placements[position.positionKey] else { continue }
            guard placements[placement] == nil,
                  let address = position.h5Url, let url = URL(string: address) else { continue }
            let mode = position.displayModeKey.flatMap(WebPaywallConfiguration.Presentation.init(rawValue:))
                ?? .fullScreen
            let document: WebPaywallDocument
            do {
                if let existing = loaded[url] { document = existing }
                else {
                    document = try await WebPaywallPackageLoader.load(
                        pageURL: url, runtimeEnvironment: configuration.runtimeEnvironment.rawValue,
                        allowedOrigins: configuration.allowedOrigins,
                        catalog: catalog, developmentHTTPOrigin: configuration.developmentHTTPOrigin)
                    loaded[url] = document
                }
                try Task.checkCancellation()
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                WebPaywallDiagnostics.log(configuration.runtimeEnvironment.rawValue,
                                          "query.page_skipped", "placement=\(placement) error=\(error)")
                continue
            }
            // 同一文档的冲突配置只影响当前点位，不覆盖已成功解析的页面。
            if let existing = paywalls[document.documentId], existing["pageUrl"] as? String != document.pageURL.absoluteString {
                continue
            }
            guard paywalls[document.documentId] != nil || paywalls.count < 8 else { continue }
            placements[placement] = document.documentId
            presentations[placement] = mode.rawValue
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
