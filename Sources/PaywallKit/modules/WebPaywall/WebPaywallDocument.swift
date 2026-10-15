import Foundation

/// H5 页面清单。页面布局由 CDN 更新，商店商品仍由宿主目录限定。
public struct WebPaywallDocument {
    public let documentId: String
    public let revision: Int?
    public let pageURL: URL
    public let catalogKey: String
    public let productRefs: [String]
    public let initialProductRef: String
    let localReadAccessURL: URL?

    /// 校验页面清单；显式传 nil 关闭来源白名单，空集合仍拒绝全部来源。
    public init(data: Data, allowedOrigins: Set<String>?, catalog: PaywallCatalog,
                developmentHTTPOrigin: String? = nil) throws {
        // 本机 HTTP 仅供 Debug 演示；正式清单仍必须指向 HTTPS。
        #if DEBUG
        let localHTTPOrigin = developmentHTTPOrigin
        #else
        let localHTTPOrigin: String? = nil
        #endif
        guard data.count <= 256_000,
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(raw.keys) == Set(["kind", "bridgeVersion", "documentId", "revision", "pageUrl",
                                    "catalogKey", "productRefs", "initialProductRef"]),
              raw["kind"] as? String == "web-paywall",
              raw["bridgeVersion"] as? Int == 2,
              let revision = raw["revision"] as? Int, revision >= 1,
              let documentId = raw["documentId"] as? String, !documentId.isEmpty,
              let pageString = raw["pageUrl"] as? String,
              let pageURL = URL(string: pageString),
              pageURL.scheme == "https" ||
                  (pageURL.scheme == "http" && Self.origin(of: pageURL) == localHTTPOrigin),
              pageURL.user == nil, pageURL.password == nil, pageURL.fragment == nil,
              pageURL.query == nil,
              pageURL.host?.isEmpty == false,
              allowedOrigins.map({ $0.contains(Self.origin(of: pageURL)) }) ?? true,
              let catalogKey = raw["catalogKey"] as? String, !catalogKey.isEmpty,
              let refs = raw["productRefs"] as? [String], !refs.isEmpty,
              refs.count == Set(refs).count,
              refs.allSatisfy({ catalog.productRefs.contains($0) }),
              let initial = raw["initialProductRef"] as? String, refs.contains(initial)
        else { throw WebPaywallError.invalidDocument }
        self.documentId = documentId
        self.revision = revision
        self.pageURL = pageURL
        self.catalogKey = catalogKey
        self.productRefs = refs
        self.initialProductRef = initial
        self.localReadAccessURL = nil
    }

    /// 从宿主 App 自身的资源目录读取离线页面；不接受任意 file:// 路径。
    public init(bundledDirectory: URL, catalog: PaywallCatalog) throws {
        guard let appResources = Bundle.main.resourceURL?.resolvingSymlinksInPath().standardizedFileURL,
              bundledDirectory.isFileURL else { throw WebPaywallError.invalidDocument }
        let directory = bundledDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard directory.path.hasPrefix(appResources.path + "/"),
              (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        else { throw WebPaywallError.invalidDocument }

        let page = directory.appendingPathComponent("index.html")
        let configFile = directory.appendingPathComponent("page.json")
        guard [page, configFile].allSatisfy({
            $0.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(directory.path + "/")
        }),
              let configData = try? Data(contentsOf: configFile), configData.count <= 256_000,
              let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
              Set(config.keys) == Set(["documentId", "catalogKey", "productRefs", "initialProductRef"]),
              let documentId = config["documentId"] as? String, !documentId.isEmpty,
              let catalogKey = config["catalogKey"] as? String, !catalogKey.isEmpty,
              let refs = config["productRefs"] as? [String], !refs.isEmpty,
              refs.count == Set(refs).count,
              refs.allSatisfy({ catalog.productRefs.contains($0) }),
              let initial = config["initialProductRef"] as? String, refs.contains(initial),
              FileManager.default.fileExists(atPath: page.path),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("content.json").path)
        else { throw WebPaywallError.invalidDocument }

        self.documentId = documentId
        self.revision = nil
        self.pageURL = page
        self.catalogKey = catalogKey
        self.productRefs = refs
        self.initialProductRef = initial
        self.localReadAccessURL = directory
    }

    /// 只供已校验的本地包仓库使用，商品绑定仍受宿主注册目录限制。
    init(packageDirectory: URL, identity: WebPaywallPackage.Document,
         environment: String, catalog: PaywallCatalog) throws {
        guard !identity.productRefs.isEmpty,
              identity.productRefs.allSatisfy({ catalog.productRefs.contains($0) }),
              identity.productRefs.contains(identity.initialProductRef) else {
            throw WebPaywallError.invalidDocument
        }
        try WebPaywallPackage.verify(packageDirectory, identity: identity, environment: environment)
        self.init(documentId: identity.documentId, revision: identity.revision,
                  pageURL: packageDirectory.appendingPathComponent("offline.html"),
                  catalogKey: identity.catalogKey, productRefs: identity.productRefs,
                  initialProductRef: identity.initialProductRef, localReadAccessURL: packageDirectory)
    }

    public static func origin(of url: URL) -> String {
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(url.scheme ?? "")://\(url.host ?? "")\(port)"
    }

    /// 宿主按已冻结的地区商品快照收窄下发清单，不允许加入服务端未授权的商品。
    public func selectingProductRefs(_ references: [String]) throws -> WebPaywallDocument {
        guard !references.isEmpty,
              references.count == Set(references).count,
              references.allSatisfy({ productRefs.contains($0) }) else {
            throw WebPaywallError.invalidDocument
        }
        return WebPaywallDocument(
            documentId: documentId, revision: revision, pageURL: pageURL,
            catalogKey: catalogKey, productRefs: references,
            initialProductRef: references[0], localReadAccessURL: localReadAccessURL
        )
    }

    private init(documentId: String, revision: Int?, pageURL: URL, catalogKey: String,
                 productRefs: [String], initialProductRef: String, localReadAccessURL: URL?) {
        self.documentId = documentId
        self.revision = revision
        self.pageURL = pageURL
        self.catalogKey = catalogKey
        self.productRefs = productRefs
        self.initialProductRef = initialProductRef
        self.localReadAccessURL = localReadAccessURL
    }
}

public enum WebPaywallError: Error { case invalidDocument }
