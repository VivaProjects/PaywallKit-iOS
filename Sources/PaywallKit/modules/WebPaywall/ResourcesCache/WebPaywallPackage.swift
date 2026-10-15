import Foundation
import CryptoKit

/// 持久包描述静态资源与商品绑定；实际发布地址由宿主文档决定。
struct WebPaywallPackage: Codable {
    struct Document: Codable, Equatable {
        let kind: String
        let bridgeVersion: Int
        let documentId: String
        let revision: Int
        let pageUrl: String
        let catalogKey: String
        let productRefs: [String]
        let initialProductRef: String

        /// 使用宿主下发的发布地址，保留包内页面身份、版本与商品绑定。
        func usingPageURL(_ address: String) -> Self {
            Self(kind: kind, bridgeVersion: bridgeVersion, documentId: documentId,
                 revision: revision, pageUrl: address, catalogKey: catalogKey,
                 productRefs: productRefs, initialProductRef: initialProductRef)
        }
    }
    struct File: Codable {
        let path: String
        let size: Int
        let sha256: String
    }
    let formatVersion: Int
    let runtimeEnvironment: String
    let document: Document
    let documents: [String: Document]?
    let entry: String
    let files: [File]

    /// 共享包只共享资源身份，按宿主环境选择整套商品绑定；旧单环境包继续可读。
    func identity(for environment: String) throws -> Document {
        guard ["test", "production"].contains(environment) else { throw WebPaywallError.invalidDocument }
        if formatVersion == 1, runtimeEnvironment == environment { return document }
        guard formatVersion == 2, runtimeEnvironment == "shared",
              let documents, Set(documents.keys) == Set(["test", "production"]),
              documents["test"] == document, let selected = documents[environment],
              documents.values.allSatisfy({
                  $0.kind == document.kind && $0.bridgeVersion == document.bridgeVersion &&
                  $0.documentId == document.documentId && $0.revision == document.revision &&
                  $0.pageUrl == document.pageUrl && $0.catalogKey == document.catalogKey &&
                  !$0.productRefs.isEmpty && Set($0.productRefs).count == $0.productRefs.count &&
                  $0.productRefs.contains($0.initialProductRef)
              }) else { throw WebPaywallError.invalidDocument }
        return selected
    }

    /// 保持远端身份与本地文件地址分离，不允许旧包借用新绑定。
    static func identity(_ source: WebPaywallDocument) throws -> Document {
        guard let revision = source.revision else { throw WebPaywallError.invalidDocument }
        return Document(kind: "web-paywall", bridgeVersion: 2, documentId: source.documentId,
                        revision: revision, pageUrl: source.pageURL.absoluteString,
                        catalogKey: source.catalogKey, productRefs: source.productRefs,
                        initialProductRef: source.initialProductRef)
    }

    /// 网络与磁盘均校验资源和绑定；包内发布地址不覆盖宿主指定地址。
    static func parse(_ data: Data, identity: Document, environment: String) throws -> Self {
        guard data.count <= 256_000 else { throw WebPaywallError.invalidDocument }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard identity.kind == "web-paywall", identity.bridgeVersion == 2, identity.revision >= 1,
              !identity.productRefs.isEmpty, Set(identity.productRefs).count == identity.productRefs.count,
              identity.productRefs.contains(identity.initialProductRef),
              try value.identity(for: environment).usingPageURL(identity.pageUrl) == identity,
              value.entry == "offline.html",
              !value.files.isEmpty, value.files.count <= 1_000,
              Set(value.files.map(\.path)).count == value.files.count,
              Set(["offline.html", "offline.js", "content.json", "page.json"]).isSubset(of: Set(value.files.map(\.path)))
        else { throw WebPaywallError.invalidDocument }
        var total = 0
        for file in value.files {
            guard validPath(file.path), file.path != "package.json", file.size >= 0,
                  file.size <= 100 * 1024 * 1024,
                  file.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
            else { throw WebPaywallError.invalidDocument }
            total += file.size
            guard total <= 100 * 1024 * 1024 else { throw WebPaywallError.invalidDocument }
        }
        return value
    }

    /// 校验完整资源集，内置包、更新包和普通缓存使用相同规则。
    static func verify(_ directory: URL, identity: Document, environment: String) throws {
        let manifest = directory.appendingPathComponent("package.json")
        guard manifest.resolvingSymlinksInPath().path == manifest.path,
              ((try manifest.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max) <= 256_000
        else { throw WebPaywallError.invalidDocument }
        let package = try WebPaywallPackage.parse(Data(contentsOf: manifest), identity: identity, environment: environment)
        for file in package.files {
            let url = directory.appendingPathComponent(file.path)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard url.resolvingSymlinksInPath().path == url.path, values.isRegularFile == true,
                  values.fileSize == file.size,
                  WebPaywallPackage.digest(try Data(contentsOf: url)) == file.sha256
            else { throw WebPaywallError.invalidDocument }
        }
    }

    /// 只允许普通相对资源路径，拒绝编码、隐藏目录与父目录跳转。
    static func validPath(_ path: String) -> Bool {
        path.range(of: "^[A-Za-z0-9_-][A-Za-z0-9_./-]*$", options: .regularExpression) != nil &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".")
        }
    }

    /// 统一校验缓存身份与文件内容摘要。
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
