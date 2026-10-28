import Foundation

/// 本地包只把冻结的数据交给后台，宿主授权与状态变更仍由主线程决定。
enum WebPaywallLocalDocumentLoader {
    /// 逐文件完整校验；调用者取消只丢弃结果，不把取消当成资源损坏。
    static func load(directory: URL, identity: WebPaywallPackage.Document,
                     environment: String, catalog: PaywallCatalog) async throws -> WebPaywallDocument {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try WebPaywallDocument(packageDirectory: directory, identity: identity,
                                   environment: environment, catalog: catalog)
        }
        return try await WebPaywallDiagnostics.measure(environment, "local.verify", "document=\(identity.documentId)") {
            try await result(of: task)
        }
    }

    /// Bundle 目录边界、清单解析与摘要读取均在后台完成，不能接受外部路径。
    static func bundled(directory: URL, resources: URL?, environment: String,
                        catalog: PaywallCatalog) async throws -> WebPaywallDocument {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            guard let resources = resources?.resolvingSymlinksInPath(),
                  directory.resolvingSymlinksInPath().path.hasPrefix(resources.path + "/") else {
                throw WebPaywallError.invalidDocument
            }
            let bytes = try Data(contentsOf: directory.appendingPathComponent("package.json"))
            let package = try JSONDecoder().decode(WebPaywallPackage.self, from: bytes)
            return try WebPaywallDocument(packageDirectory: directory, identity: package.identity(for: environment),
                                          environment: environment, catalog: catalog)
        }
        return try await WebPaywallDiagnostics.measure(environment, "local.bundled_verify") {
            try await result(of: task)
        }
    }
    /// 校验失败与调用者取消同时发生时优先返回取消，不把有效版本标记为坏包。
    private static func result(of task: Task<WebPaywallDocument, Error>) async throws -> WebPaywallDocument {
        do {
            let document = try await task.value
            try Task.checkCancellation()
            return document
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

}
