import Foundation

/// 为业务查询接口读取页面包身份，沿用 SDK 完整资源与商品校验。
public enum WebPaywallPackageLoader {
    /// 下载并校验包清单与资源；显式传 nil 关闭来源白名单，空集合仍拒绝全部来源。
    public static func load(pageURL: URL, runtimeEnvironment: String,
                            allowedOrigins: Set<String>?, catalog: PaywallCatalog,
                            developmentHTTPOrigin: String? = nil) async throws -> WebPaywallDocument {
        try await prepare(pageURL: pageURL, runtimeEnvironment: runtimeEnvironment, allowedOrigins: allowedOrigins,
                          catalog: catalog, developmentHTTPOrigin: developmentHTTPOrigin).0
    }

    /// 查询更新持有完整包租约直到归档完成，其他下载不能在提交前淘汰资源。
    static func prepare(pageURL: URL, runtimeEnvironment: String,
                        allowedOrigins: Set<String>?, catalog: PaywallCatalog,
                        developmentHTTPOrigin: String? = nil) async throws -> (WebPaywallDocument, WebPaywallResourceLease) {
        #if DEBUG
        let localOrigin = runtimeEnvironment == "test" ? developmentHTTPOrigin : nil
        #else
        let localOrigin: String? = nil
        #endif
        // 开发 HTTP 仅放行宿主指定的唯一来源，仍逐项校验完整页面包。
        guard pageURL.scheme == "https" ||
                (pageURL.scheme == "http" && WebPaywallDocument.origin(of: pageURL) == localOrigin), pageURL.user == nil, pageURL.password == nil,
              pageURL.query == nil, pageURL.fragment == nil,
              pageURL.lastPathComponent == "index.html",
              pageURL.host?.isEmpty == false,
              allowedOrigins.map({ $0.contains(WebPaywallDocument.origin(of: pageURL)) }) ?? true else {
            throw WebPaywallError.invalidDocument
        }
        let url = pageURL.deletingLastPathComponent().appendingPathComponent("package.json")
        let transport = WebPaywallResourceDownload()
        defer { transport.close() }
        let bytes = try await transport.fetch(url, limit: 256_000,
                                                               deadline: Date().addingTimeInterval(15))
        let package = try JSONDecoder().decode(WebPaywallPackage.self, from: bytes)
        // 查询接口地址是实际发布位置，包内旧路径不参与下载与缓存身份。
        let identity = try package.identity(for: runtimeEnvironment).usingPageURL(pageURL.absoluteString)
        _ = try WebPaywallPackage.parse(bytes, identity: identity, environment: runtimeEnvironment)
        let document = try WebPaywallDocument(data: JSONEncoder().encode(identity),
                                             allowedOrigins: allowedOrigins, catalog: catalog,
                                             developmentHTTPOrigin: localOrigin)
        let lease = try await WebPaywallResourceCache.shared.prepare(document: document,
                                                                    runtimeEnvironment: runtimeEnvironment,
                                                                    downloadTimeout: 120, manifestData: bytes)
        try Task.checkCancellation()
        // 来源和商品目录已由 document 校验；prepare 已完整校验清单及文件。
        // 将同一租约交给归档，复制后的目标仍独立复验。
        return (document, lease)
    }
}
