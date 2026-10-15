import Foundation

/// 独立保存兜底包，不受普通网页缓存清理影响；业务名称由宿主注入。
@MainActor
public final class PaywallLocalPackageStore {
    private struct Update: Codable {
        let formatVersion: Int
        let runtimeEnvironment: String
        let version: Int
        let document: WebPaywallPackage.Document
        let documents: [String: WebPaywallPackage.Document]?
        let disabledPlacements: [String]
    }
    /// 更新描述的两套绑定共享版本和资源地址，禁止只替换商品 ID 借用另一份包。
    private func identity(_ update: Update) throws -> WebPaywallPackage.Document {
        if update.formatVersion == 1, update.runtimeEnvironment == environment { return update.document }
        guard update.formatVersion == 2, update.runtimeEnvironment == "shared",
              let documents = update.documents, Set(documents.keys) == Set(["test", "production"]),
              documents["test"] == update.document, let selected = documents[environment],
              documents.values.allSatisfy({
                  $0.kind == update.document.kind && $0.bridgeVersion == update.document.bridgeVersion &&
                  $0.documentId == update.document.documentId && $0.revision == update.version &&
                  $0.pageUrl == update.document.pageUrl && $0.catalogKey == update.document.catalogKey
              }) else { throw PaywallFailure.configuration }
        return selected
    }

    private struct Record: Codable {
        let update: Update
        let directory: String
    }
    private struct State: Codable {
        var current: Record?
        var previous: Record?
        var rejected: Set<Int> = []
        var highestVersion = 0
        var policyVersion = 0
        var disabledPlacements: Set<String> = []
    }

    public let placement: String
    public let fallbackPlacements: Set<String>
    private let bundledDirectory: URL
    private let updateURL: URL?
    private let environment: String
    private let origins: Set<String>?
    private let developmentHTTPOrigin: String?
    private let catalog: () -> PaywallCatalog
    private let root: URL
    private let cache: WebPaywallResourceCache
    private var state = State()
    private var lastCheck: Date?
    private var checking = false

    public init(placement: String, fallbackPlacements: Set<String>, bundledDirectory: URL,
                updateURL: URL? = nil, runtimeEnvironment: String, allowedOrigins: Set<String>?,
                developmentHTTPOrigin: String? = nil, cacheNamespace: String,
                catalog: @escaping () -> PaywallCatalog) {
        self.placement = placement
        self.fallbackPlacements = fallbackPlacements
        self.bundledDirectory = bundledDirectory
        self.updateURL = updateURL
        environment = runtimeEnvironment
        origins = allowedOrigins
        self.developmentHTTPOrigin = developmentHTTPOrigin
        self.catalog = catalog
        let namespace = WebPaywallPackage.digest(Data(cacheNamespace.utf8))
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaywallKit/LocalPackages/\(namespace)/\(runtimeEnvironment)")
        cache = WebPaywallResourceCache(directory: root.appendingPathComponent("packages"),
                                       capacityBytes: Int.max, downloadTimeout: 120)
        restoreState()
    }

    /// 只在创建仓库时清理历史目录，此时尚无展示会话持有它们。
    private func restoreState() {
        let file = root.appendingPathComponent("state.json")
        if let bytes = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(State.self, from: bytes) { state = saved }
        let kept = Set([state.current?.directory, state.previous?.directory].compactMap { $0 })
        let directory = root.appendingPathComponent("packages")
        if let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for child in children where !kept.contains(child.lastPathComponent) {
                try? FileManager.default.removeItem(at: child)
            }
        }
    }

    /// 读取本地冻结版本，打开页面绝不等待网络。
    func selection(bundledOnly: Bool = false) throws -> (WebPaywallDocument, String) {
        if !bundledOnly {
            for record in [state.current, state.previous].compactMap({ $0 })
                where !state.rejected.contains(record.update.version) {
                if let document = try? localDocument(record) { return (document, "update") }
                state.rejected.insert(record.update.version)
                try? persist()
            }
        }
        guard let resources = Bundle.main.resourceURL?.resolvingSymlinksInPath(),
              bundledDirectory.resolvingSymlinksInPath().path.hasPrefix(resources.path + "/") else {
            throw PaywallFailure.resource
        }
        let bytes = try Data(contentsOf: bundledDirectory.appendingPathComponent("package.json"))
        let package = try JSONDecoder().decode(WebPaywallPackage.self, from: bytes)
        let document = try WebPaywallDocument(packageDirectory: bundledDirectory, identity: try package.identity(for: environment),
                                             environment: environment, catalog: catalog())
        return (document, "bundled")
    }

    /// 历史版本也重新校验环境、清单、目录与商品，不能借用新绑定。
    private func localDocument(_ record: Record) throws -> WebPaywallDocument {
        guard record.directory.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw PaywallFailure.resource
        }
        return try WebPaywallDocument(
            packageDirectory: root.appendingPathComponent("packages/\(record.directory)"),
            identity: try identity(record.update), environment: environment, catalog: catalog())
    }

    /// 显式关闭与点位缺失分离，离线时保留上次成功发布的决定。
    func isDisabled(_ name: String) -> Bool { state.disabledPlacements.contains(name) }

    /// 只有资源或桥故障隔离更新包，商店离线不能污染版本健康状态。
    func reject(_ document: WebPaywallDocument) {
        guard let version = document.revision else { return }
        state.rejected.insert(version)
        try? persist()
    }

    /// 每次冷启动首次检查，前台恢复最多每小时检查一次；失败保留所有旧状态。
    @discardableResult
    public func refreshIfNeeded() async -> Bool {
        guard updateURL != nil, !checking, lastCheck.map({ Date().timeIntervalSince($0) >= 3600 }) ?? true else { return false }
        checking = true
        lastCheck = Date()
        defer { checking = false }
        do { try await refresh(); return true }
        catch is CancellationError { lastCheck = nil; return false }
        catch {
            if Task.isCancelled { lastCheck = nil; return false }
            WebPaywallDiagnostics.log(environment, "local_package.update_failed", "code=\((error as NSError).code)")
            return false
        }
    }

    /// 下载描述和完整资源后才原子激活；发布失败不能改变正在展示的包。
    private func refresh() async throws {
        guard let updateURL else { return }
        try validateUpdateURL(updateURL)
        let bytes = try await WebPaywallResourceDownload().fetch(updateURL, limit: 256_000,
                                                                deadline: Date().addingTimeInterval(15))
        let update = try JSONDecoder().decode(Update.self, from: bytes)
        let selected = try identity(update)
        guard update.version >= 1, update.version == selected.revision else {
            throw PaywallFailure.configuration
        }
        let data = try JSONEncoder().encode(selected)
        let document = try WebPaywallDocument(data: data, allowedOrigins: origins, catalog: catalog(),
                                             developmentHTTPOrigin: developmentHTTPOrigin)
        // 即使包未更新，也接收显式开关；版本回退不能覆盖已接受的新配置。
        guard update.version >= max(state.highestVersion, state.policyVersion) else { return }
        state.disabledPlacements = Set(update.disabledPlacements)
        state.policyVersion = update.version
        try persist()
        guard update.version > state.highestVersion, !state.rejected.contains(update.version) else { return }
        let lease = try await cache.prepare(document: document, runtimeEnvironment: environment)
        try Task.checkCancellation()
        _ = try WebPaywallDocument(packageDirectory: lease.readAccessURL, identity: selected,
                                  environment: environment, catalog: catalog())
        let old = state
        state.previous = [state.current, state.previous].compactMap { $0 }
            .first { !state.rejected.contains($0.update.version) }
        state.current = Record(update: update, directory: lease.readAccessURL.lastPathComponent)
        state.highestVersion = update.version
        do { try persist() } catch { state = old; throw error }
        WebPaywallDiagnostics.log(environment, "local_package.updated", "version=\(update.version)")
    }

    /// 接收查询接口选中的 Settings 完整包；资源校验成功后才更新兜底指针。
    public func adopt(_ document: WebPaywallDocument) async throws {
        let selected = try WebPaywallPackage.identity(document)
        _ = try WebPaywallDocument(data: JSONEncoder().encode(selected), allowedOrigins: origins,
                                  catalog: catalog(), developmentHTTPOrigin: developmentHTTPOrigin)
        guard selected.revision > state.highestVersion,
              !state.rejected.contains(selected.revision) else { return }
        let lease = try await cache.prepare(document: document, runtimeEnvironment: environment)
        try Task.checkCancellation()
        _ = try WebPaywallDocument(packageDirectory: lease.readAccessURL, identity: selected,
                                  environment: environment, catalog: catalog())
        // 同一版本并发返回时只提交一次，失败则恢复原来的可用指针。
        guard selected.revision > state.highestVersion else { return }
        let old = state
        let update = Update(formatVersion: 1, runtimeEnvironment: environment,
                            version: selected.revision, document: selected, documents: nil,
                            disabledPlacements: [])
        state.previous = state.current
        state.current = Record(update: update, directory: lease.readAccessURL.lastPathComponent)
        state.highestVersion = selected.revision
        do { try persist() } catch { state = old; throw error }
    }

    /// 描述和资源来源采用同一信任边界，禁止重定向。
    private func validateUpdateURL(_ updateURL: URL) throws {
        #if DEBUG
        let permitsHTTP = WebPaywallDocument.origin(of: updateURL) == developmentHTTPOrigin
        #else
        let permitsHTTP = false
        #endif
        guard ["test", "production"].contains(environment),
              updateURL.scheme == "https" || (updateURL.scheme == "http" && permitsHTTP),
              origins.map({ $0.contains(WebPaywallDocument.origin(of: updateURL)) }) ?? true,
              updateURL.user == nil, updateURL.password == nil, updateURL.fragment == nil else {
            throw PaywallFailure.configuration
        }
    }

    /// 指针单文件原子替换，静态包与元数据均排除系统备份。
    private func persist() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var location = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try location.setResourceValues(values)
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("state.json"), options: .atomic)
    }
}
