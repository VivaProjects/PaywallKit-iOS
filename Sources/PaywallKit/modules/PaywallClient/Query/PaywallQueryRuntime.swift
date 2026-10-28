import Foundation

/// 启动时冻结各点位缓存，唯一后台查询只补齐本次缺失并提交下次启动候选。
@MainActor
final class PaywallQueryRuntime {
    private let configuration: PaywallQueryConfiguration
    private let catalog: () -> PaywallCatalog
    private let attribution: PaywallQueryAttribution
    private let snapshots: PaywallQuerySnapshotStore
    private weak var client: PaywallClient?
    private var activeIdentity: String?
    private var activePlacements: [String: PaywallPlacement] = [:]
    private var restoreTask: Task<Void, Never>?
    private var restoredPlacements: Set<String> = []
    private var queryTask: Task<Void, Error>?
    private var queryFinished = false
    private var unavailablePlacements: Set<String> = []
    private var deferredPlacements: Set<String> = []
    private var preferredPlacement: String?
    private var queryFailure: Error?
    private var progressObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private(set) var fallbackAtLaunch: PaywallPlacement?

    var hasConfiguration: Bool { !activePlacements.isEmpty || queryFinished }

    /// 缓存范围由 SDK 隔离，宿主仍只提供声明和当前商品目录。
    init(configuration: PaywallQueryConfiguration, catalog: @escaping () -> PaywallCatalog) {
        self.configuration = configuration
        self.catalog = catalog
        attribution = PaywallQueryAttribution(namespace: configuration.cacheScope)
        snapshots = PaywallQuerySnapshotStore(configuration: configuration)
    }

    deinit { queryTask?.cancel(); restoreTask?.cancel() }

    /// 通用来源仅用于历史校验和精确身份的旧缓存迁移，不改变自定义来源策略。
    func source() -> PaywallConfigurationSource {
        PaywallConfigurationSource(
            cacheNamespace: configuration.cacheScope, allowedOrigins: configuration.allowedOrigins,
            developmentHTTPOrigin: configuration.developmentHTTPOrigin,
            catalogs: { ["default": self.catalog()] },
            runtimeEnvironment: configuration.runtimeEnvironment.rawValue,
            requestIdentity: { PaywallQueryRequest.identity($0, namespace: self.configuration.cacheScope) },
            isCurrentRequest: { self.activeIdentity == PaywallQueryRequest.identity($0, namespace: self.configuration.cacheScope) },
            responseTransform: { try await PaywallQueryResponse.transform($0, configuration: self.configuration, catalog: self.catalog()) },
            request: { try await self.request() })
    }

    /// 绑定后异步恢复启动缓存，初始化不再同步读取所有资源。
    func attach(to client: PaywallClient) {
        self.client = client
        installBundledFallback(on: client)
        startRestore()
    }

    /// 同步读取恢复状态，已完成的本地入口可继续直接复用预热页面。
    func hasRestored(_ placement: String) -> Bool { restoredPlacements.contains(placement) }

    /// 当前点位独立等待完整校验，不被其他点位资源读取阻塞。
    func restorePlacement(_ placement: String) async throws {
        if restoredPlacements.contains(placement) { return }
        let candidate = await WebPaywallDiagnostics.measure(configuration.runtimeEnvironment.rawValue,
            "snapshot.restore", "query=\(diagnosticID) placement=\(placement)") {
            await snapshots.restore(placement, catalog: catalog())
        }
        try Task.checkCancellation()
        guard !restoredPlacements.contains(placement) else { return }
        restoredPlacements.insert(placement)
        guard let candidate, let client else { return }
        do {
            let selected = try candidate.snapshot.resolve(using: configuration, catalog: catalog(),
                clientID: client.id, lease: candidate.lease, localDocument: candidate.document)
            activePlacements[selected.name] = selected
            if selected.name == configuration.fallback?.placement { fallbackAtLaunch = selected }
            trace("query.cache_restored", "placement=\(selected.name) revision=\(selected.document.revision ?? 0)")
            progressObservers.values.forEach { $0.yield(()) }
        } catch { trace("query.cache_invalid", "placement=\(placement)") }
    }

    /// 剩余点位后台恢复；优先级仅改变未开始的工作，不改变启动版本选择。
    private func startRestore() {
        guard restoreTask == nil else { return }
        let snapshots = self.snapshots
        restoreTask = Task { [weak self] in
            var pending = await snapshots.restoreNames()
            while !pending.isEmpty && !Task.isCancelled {
                guard let self else { return }
                let index = self.preferredPlacement.flatMap { pending.firstIndex(of: $0) } ?? 0
                let name = pending.remove(at: index)
                try? await self.restorePlacement(name)
            }
        }
    }

    /// 有缓存立即返回；无缓存只等首个完整点位，不阻塞于剩余后台下载。
    func prepare() async throws {
        _ = startQuery()
        try await waitForPlacement(nil)
    }

    /// 缺失点位只等自身就绪，关闭入口不取消唯一后台更新。
    func resolve(_ placement: String, presentation: Bool = false) async throws -> PaywallPlacement? {
        preferredPlacement = placement
        try await restorePlacement(placement)
        _ = startQuery()
        try await waitForPlacement(placement, presentation: presentation)
        return activePlacements[placement]
    }

    /// 点位就绪或响应确认不可用时结束等待；取消仅移除当前等待者。
    private func waitForPlacement(_ placement: String?, presentation: Bool = false) async throws {
        try Task.checkCancellation()
        if canFinishWaiting(placement) { return }
        if !queryFinished {
            let token = UUID()
            let progress = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) {
                progressObservers[token] = $0
            }
            // 仅可见入口设置三秒期限；结束等待不会取消共享下载。
            let timeout: Task<Void, Never>? = presentation ? Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 3_000_000_000) }
                catch { return }
                guard let self, let placement, !self.canFinishWaiting(placement) else { return }
                self.deferredPlacements.insert(placement)
                self.trace("query.presentation_timeout", "placement=\(placement) seconds=3")
                self.progressObservers.values.forEach { $0.yield(()) }
            } : nil
            defer {
                timeout?.cancel()
                progressObservers.removeValue(forKey: token)?.finish()
            }
            // MainActor 内先注册再挂起，提交通知不会落在检查与订阅之间。
            for await _ in progress {
                try Task.checkCancellation()
                if canFinishWaiting(placement) { return }
            }
        }
        try Task.checkCancellation()
        // 已提交结果优先，后续其他包或索引失败不能让可用点位退回兜底。
        if !canFinishWaiting(placement), let queryFailure { throw queryFailure }
    }

    /// 启动准备等待任一完整点位；具体入口也可在响应确认不可用后立即兜底。
    private func canFinishWaiting(_ placement: String?) -> Bool {
        if let placement {
            return activePlacements[placement] != nil || unavailablePlacements.contains(placement)
                || deferredPlacements.contains(placement)
        }
        return !activePlacements.isEmpty
    }

    /// 唤醒响应中没有下载候选的入口，不修改启动快照或终止其他包下载。
    private func markUnavailable(_ placements: Set<String>) {
        // 已恢复的启动快照继续供本次使用，后台响应不撤换当前版本。
        unavailablePlacements.formUnion(placements.subtracting(Set(activePlacements.keys)))
        for placement in unavailablePlacements.sorted() {
            trace("query.placement_unavailable", "placement=\(placement) reason=no_download_candidate")
        }
        // 等待者只检查自己的点位，命中的入口仍等待对应包校验完成。
        progressObservers.values.forEach { $0.yield(()) }
    }

    /// 可见入口提升尚未开始的下载，后台预加载不覆盖用户选择。
    func prioritize(_ placement: String) {
        preferredPlacement = placement
        trace("query.prioritize", "placement=\(placement)")
    }

    /// 同步读取本次冻结的点位，后台提交不会改变其版本或预加载身份。
    func cachedPlacement(_ placement: String) -> PaywallPlacement? { activePlacements[placement] }

    /// 迟到归因只保存给下次请求，不触发额外查询或替换已有点位。
    func reportAttribution(channel: String?, failed: Bool) { attribution.update(channel: channel, failed: failed) }

    /// 成功和失败任务都保留到运行时释放，关闭弹窗及前台恢复不重新查询。
    private func startQuery() -> Task<Void, Error> {
        if let queryTask { return queryTask }
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            defer {
                self.queryFinished = true
                self.progressObservers.values.forEach { $0.finish() }
            }
            do { try await self.update() }
            catch {
                self.queryFailure = error
                if !(error is CancellationError), !Task.isCancelled {
                    self.trace("query.update_failed", "code=\((error as NSError).code)")
                    self.report(.failed)
                }
                throw error
            }
        }
        queryTask = task
        return task
    }

    /// 联网后仅采集一次请求条件，离线等待不消耗归因期限或覆盖启动快照。
    private func request() async throws -> URLRequest {
        // 网络状态未知或离线时挂起唯一任务，已有点位仍可直接使用缓存。
        try await WebPaywallDiagnostics.measure(configuration.runtimeEnvironment.rawValue, "query.network_wait") {
            try await configuration.waitUntilNetworkAvailable?()
        }
        try Task.checkCancellation()
        // 首次联网后才开始等待归因，避免离线期间耗尽五秒窗口。
        let request = try await PaywallQueryRequest.request(configuration: configuration, attribution: attribution)
        try Task.checkCancellation()
        guard request.httpBody != nil else { throw WebPaywallError.invalidDocument }
        activeIdentity = PaywallQueryRequest.identity(request, namespace: configuration.cacheScope)
        return request
    }

    /// 唯一查询补齐缺失点位，已有点位的新结果仅写入下次启动索引。
    private func update() async throws {
        // 请求与恢复重叠；冻结完成前不应用网络结果或迁移持久指针。
        let (request, bytes) = try await PaywallQueryStartup.load(
            restore: { await self.restoreTask?.value },
            prepare: { try await self.request() },
            fetch: { try await self.queryBytes($0) },
            frozen: { await self.migrateLegacy($0) })
        let archiveBatch = PaywallQueryArchiveBatch()
        var failures = 0
        var updatedPlacements = 0
        // 每个完整包立即归档，已完成点位不再等待其余包。
        let batch = try await PaywallQueryResponse.load(bytes, configuration: configuration, catalog: catalog(), maximumConcurrentPackages: 2,
            preferredPlacement: { self.preferredPlacement },
            onUnavailable: { self.markUnavailable($0) }) { page in
            do {
                let changed = try self.requiresUpdate(page)
                try await self.accept(page, request: request, batch: archiveBatch)
                if changed { updatedPlacements += 1 }
            }
            catch is CancellationError { throw CancellationError() }
            catch {
                failures += 1
                self.trace("query.snapshot_failed", "placement=\(page.placement)")
            }
        }
        try Task.checkCancellation()
        do { try await snapshots.remove(batch.unmatched) }
        catch {
            failures += 1
            trace("query.snapshot_failed", "operation=remove_unmatched")
        }
        trace("query.update_finished", "updated=\(updatedPlacements) unmatched=\(batch.unmatched.count) failures=\(failures + batch.failures)")
        report(.completed(updatedPlacements: updatedPlacements, failures: failures + batch.failures))
    }

    /// 比较完整发布身份与展示方式，同版本缓存校验完成不计为新更新。
    private func requiresUpdate(_ page: PaywallQueryResponse.Page) throws -> Bool {
        guard let current = activePlacements[page.placement] else { return true }
        let document = current.remoteDocument ?? current.document
        return try WebPaywallPackage.identity(document) != WebPaywallPackage.identity(page.document)
            || current.presentation != page.presentation
    }

    /// 先校验再提交，当前已有版本绝不被后台结果替换。
    private func accept(_ page: PaywallQueryResponse.Page, request: URLRequest,
                        batch: PaywallQueryArchiveBatch? = nil) async throws {
        guard let client, let body = request.httpBody else { throw CancellationError() }
        let snapshot = PaywallQuerySnapshot(placement: page.placement,
            requestIdentity: PaywallQueryRequest.identity(request, namespace: configuration.cacheScope), requestBody: body,
            configuration: try PaywallQueryResponse.configurationData(placement: page.placement,
                document: page.document, presentation: page.presentation), identity: try WebPaywallPackage.identity(page.document))
        let candidate = try await snapshots.save(snapshot, resource: page.resource, batch: batch)
        let selected = try snapshot.resolve(using: configuration, catalog: catalog(), clientID: client.id, lease: candidate.lease, localDocument: candidate.document)
        trace("query.cache_staged", "placement=\(page.placement) revision=\(page.document.revision ?? 0)")
        // 超时走兜底的点位保持冻结，迟到包只供下次冷启动使用。
        if activePlacements[page.placement] == nil, !deferredPlacements.contains(page.placement) {
            activePlacements[page.placement] = selected
            trace("query.placement_ready", "placement=\(page.placement)")
            progressObservers.values.forEach { $0.yield(()) }
        }
    }

    /// 旧缓存只按本次确切请求身份迁移，且只读取已经存在的完整资源。
    private func migrateLegacy(_ request: URLRequest) async {
        guard !snapshots.hasIndex, let value = try? source().cachedConfiguration(for: request) else { return }
        for placement in value.placements.keys.sorted() {
            guard let document = value.document(forPlacement: placement),
                  let mode = value.presentations[placement] else { continue }
            do {
                let lease = try await WebPaywallResourceCache.shared.cachedPackage(
                    document: document, environment: configuration.runtimeEnvironment.rawValue)
                try Task.checkCancellation()
                try await accept(PaywallQueryResponse.Page(placement: placement, document: document,
                                                    presentation: mode, resource: lease), request: request)
            } catch is CancellationError { return }
            catch { continue }
        }
    }

    /// 内置兜底在本次进程固定；恢复的更新包通过独立启动快照提供。
    private func installBundledFallback(on client: PaywallClient) {
        guard let fallback = configuration.fallback else { return }
        let store = PaywallLocalPackageStore(placement: fallback.placement,
            fallbackPlacements: fallback.fallbackPlacements, bundledDirectory: fallback.bundledDirectory,
            runtimeEnvironment: configuration.runtimeEnvironment.rawValue, allowedOrigins: configuration.allowedOrigins,
            developmentHTTPOrigin: configuration.developmentHTTPOrigin,
            cacheNamespace: "\(configuration.cacheScope).packages.bundled", catalog: catalog)
        client.useLocalPackages(store, previousVersionPlacements: fallback.previousVersionPlacements)
    }

    /// 重试复用同一请求条件；每次发送前等待联网，成功后才进入下载队列。
    private func queryBytes(_ request: URLRequest) async throws -> Data {
        try await PaywallQueryRetry.run(environment: configuration.runtimeEnvironment.rawValue, stage: "configuration") {
            try await self.configuration.waitUntilNetworkAvailable?()
            try Task.checkCancellation()
            let (bytes, response) = try await PaywallConfigurationDiagnostics.data(
                for: request, environment: self.configuration.runtimeEnvironment.rawValue)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw WebPaywallError.invalidDocument }
            guard http.statusCode == 200 else { throw PaywallQueryRetry.HTTPFailure(status: http.statusCode) }
            guard bytes.count <= 1_000_000 else { throw WebPaywallError.invalidDocument }
            return bytes
        }
    }

    /// 只报告最终结果，控制台打印开关不影响诊断回调。
    private func report(_ diagnostic: PaywallQueryUpdateDiagnostic) {
        configuration.onUpdateDiagnostic?(diagnostic)
    }

    /// 记录缓存阶段及点位。
    private let diagnosticID = UUID().uuidString

    private func trace(_ event: String, _ detail: String) {
        WebPaywallDiagnostics.log(configuration.runtimeEnvironment.rawValue, event, "query=\(diagnosticID) \(detail)")
    }
}
