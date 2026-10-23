import Combine
import Foundation

/// 一次展示拥有独立状态与交易回调，缓存仅保存网页，不保存业务生命周期。
@MainActor
final class PaywallSessionModel: ObservableObject {
    struct Session: Identifiable {
        let id: UUID
        let input: PaywallSessionInput
        let bridge: PaywallSessionBridge
        let cache: WebPaywallWebViewCache?
    }

    enum State {
        case loading
        case ready(Session)
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    private var generation: UUID?
    private var hasReportedReady = false
    private var isClosing = false
    private var skipsInitialLoad = false
    private var fallbackContext: PaywallFallbackContext?
    private var recovering = false
    private var hasLoaded = false
    private var selectedPlacement: PaywallPlacement?
    private var historyTask: Task<Void, Never>?

    /// 就绪页在首次 body 求值前同步接管，避免弹出动画出现一个空白加载帧。
    init(prepared: PaywallPreparedPage? = nil,
         fallbackContext: PaywallFallbackContext? = nil,
         cached: () -> PaywallPreparedPage? = { nil },
         onEvent: @escaping (PaywallSessionEvent) -> Void = { _ in }) {
        self.fallbackContext = fallbackContext
        guard let prepared = prepared ?? cached() else { return }
        // 缓存页携带实际本地包来源，直接导航入口也需保留版本与曝光归因。
        self.fallbackContext = prepared.placement.fallbackContext ?? fallbackContext
        self.fallbackContext?.capture(prepared.placement)
        self.fallbackContext?.record(prepared.input.document)
        selectedPlacement = prepared.placement
        if prepared.isReady {
            skipsInitialLoad = true
            activate(input: prepared.input, cache: prepared.cache, token: UUID(), onEvent: onEvent)
        } else {
            state = .failed("The prepared paywall is no longer available.")
        }
    }

    /// 向底层传递配置开始时的期限，底层可区分商店等待与页面故障。
    var deadline: Date? { fallbackContext?.store == nil ? nil : fallbackContext?.deadline }

    /// 先解析点位，再执行宿主资格检查，取消或失效的异步结果不得重建会话。
    func load(client: PaywallClient, placement: String, resolved: PaywallPlacement?,
              cacheIdentity: AnyHashable, prepared: PaywallPreparedPage? = nil,
              prepare: @escaping (WebPaywallDocument) async throws -> PaywallSessionInput,
              onEvent: @escaping (PaywallSessionEvent) -> Void) async {
        // 预渲染会话已同步接管，首次挂载不得再次查询商品或替换 WebView。
        if skipsInitialLoad { skipsInitialLoad = false; return }
        if prepared != nil { return }
        historyTask?.cancel()
        let token = UUID()
        generation = token
        recovering = false
        hasReportedReady = false
        isClosing = false
        state = .loading
        let context = fallbackContext ?? resolved?.fallbackContext ?? client.makeFallbackContext(placement)
        if hasLoaded { context.beginPreparation() }
        hasLoaded = true
        fallbackContext = context
        var preparingInput = false
        do {
            let selected = try await select(client: client, placement: placement, resolved: resolved, context: context)
            selectedPlacement = selected
            context.capture(selected)
            preparingInput = true
            let input = try await prepareInput(selected.document, context: context, prepare: prepare)
            try Task.checkCancellation()
            guard generation == token else { return }
            context.record(input.document)
            if let resolution = context.resolution { onEvent(.resolved(resolution)) }
            activate(input: input, cache: client.pageCache(for: placement, identity: cacheIdentity, custom: input.custom),
                     token: token, onEvent: onEvent)
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled, generation == token else { return }
            let failure = error as? PaywallFailure ?? (context.usesPreviousVersion && !preparingInput ? .resource : .eligibility)
            await recover(failure, client: client, placement: placement,
                          cacheIdentity: cacheIdentity, prepare: prepare, onEvent: onEvent)
        }
    }

    /// 首次消费宿主快照，重试继续当前降级分支。
    private func select(client: PaywallClient, placement: String, resolved: PaywallPlacement?,
                        context: PaywallFallbackContext) async throws -> PaywallPlacement {
        if client.isPlacementDisabled(placement) { throw PaywallFailure.disabled }
        if context.local { return try context.localPlacement(clientID: client.id) }
        if let previous = context.previousPlacement() { return previous }
        if let resolved, resolved.name == placement, resolved.clientID == client.id { return resolved }
        if context.store == nil {
            guard let selected = try await client.resolve(placement) else { throw PaywallFailure.missingPlacement }
            return selected
        }
        return try await client.resolveForPresentation(placement, context: context)
    }

    /// 只有主动点位受共享总期限限制，其他入口保持原有准备时序。
    private func prepareInput(_ document: WebPaywallDocument, context: PaywallFallbackContext,
                              prepare: @escaping (WebPaywallDocument) async throws -> PaywallSessionInput) async throws -> PaywallSessionInput {
        guard context.store != nil else {
            return try await prepare(document).forPlacement(context.requestedPlacement)
        }
        return try await PaywallDeadline<PaywallSessionInput>().run(until: context.deadline) {
            try await prepare(document).forPlacement(context.requestedPlacement)
        }
    }

    /// 页面错误仅消费当前会话一次；每个分支失败后继续下一候选，最终显示重试。
    func recover(_ failure: PaywallFailure, sessionID: UUID? = nil, client: PaywallClient, placement: String,
                 cacheIdentity: AnyHashable,
                 prepare: @escaping (WebPaywallDocument) async throws -> PaywallSessionInput,
                 onEvent: @escaping (PaywallSessionEvent) -> Void) async {
        guard generation != nil, sessionID == nil || generation == sessionID, !recovering, !isClosing else { return }
        guard let context = fallbackContext else { fail(failure.rawValue, onEvent: onEvent); return }
        if failure.invalidatesPackage, context.resolution?.source == "update",
           case let .ready(session) = state { context.store?.reject(session.input.document) }
        historyTask?.cancel()
        recovering = true
        defer { recovering = false }
        client.invalidatePage(for: placement)
        state = .loading
        let token = UUID()
        generation = token
        var nextFailure = failure
        // advance 单向推进，历史页最多一次，Settings 更新包最多再退一次内置包。
        while generation == token && !isClosing && !Task.isCancelled {
            if nextFailure == .disabled || (context.usesPreviousVersion && [.eligibility, .cancelled].contains(nextFailure)) {
                close(onEvent: onEvent)
                return
            }
            do {
                guard let selected = try await context.advance(nextFailure, client: client) else {
                    fail(nextFailure.rawValue, onEvent: onEvent)
                    return
                }
                guard generation == token, !isClosing, !Task.isCancelled else { return }
                selectedPlacement = selected
                let input = try await prepareInput(selected.document, context: context, prepare: prepare)
                guard generation == token, !isClosing, !Task.isCancelled else { return }
                hasReportedReady = false
                if let resolution = context.resolution { onEvent(.resolved(resolution)) }
                activate(input: input, cache: client.pageCache(for: placement, identity: cacheIdentity, custom: input.custom),
                         token: token, onEvent: onEvent)
                return
            } catch is CancellationError { return }
            catch {
                nextFailure = error as? PaywallFailure ?? .configuration
                if !context.usesPreviousVersion { fail(nextFailure.rawValue, onEvent: onEvent); return }
            }
        }
    }

    /// 每次可见会话独立绑定交易事件，预加载期间不持有这组业务回调。
    private func activate(input: PaywallSessionInput, cache: WebPaywallWebViewCache?, token: UUID,
                          onEvent: @escaping (PaywallSessionEvent) -> Void) {
        generation = token
        let bridge = PaywallSessionBridge(base: input.purchaseBridge, isActive: { [weak self] in
            self?.generation == token && self?.isClosing == false
        }, event: { [weak self] event in
            self?.receive(event, token: token, onEvent: onEvent)
        })
        state = .ready(Session(id: token, input: input, bridge: bridge, cache: cache))
    }

    /// 记录底层实际命中的远端或磁盘来源，本地包身份保持更新/内置的区分。
    func resourceSource(_ source: String, session: Session) {
        guard generation == session.id else { return }
        fallbackContext?.record(session.input.document, source: source)
    }

    /// 首屏每个会话仅上报一次，商品沿用本次查询清单而非文档完整绑定。
    func ready(session: Session, productRefs: [String], client: PaywallClient,
               onEvent: (PaywallSessionEvent) -> Void) {
        guard generation == session.id, !hasReportedReady else { return }
        hasReportedReady = true
        if let selectedPlacement {
            historyTask?.cancel()
            historyTask = Task {
                await client.recordSuccess(selectedPlacement, document: session.input.document,
                                           environment: session.input.environment.runtimeEnvironment.rawValue)
            }
        }
        if let resolution = fallbackContext?.resolution { onEvent(.resolved(resolution)) }
        onEvent(.ready(productRefs: productRefs))
    }

    /// 页面错误与目录失效统一进入可重试状态，并阻止旧交易回调驱动新页面。
    func fail(_ message: String, onEvent: (PaywallSessionEvent) -> Void) {
        guard generation != nil else { return }
        historyTask?.cancel()
        generation = nil
        state = .failed(message)
        onEvent(.failed(message))
    }

    /// 退场后不再投递旧会话事件；购买和验单仍由宿主自己管理。
    func detach() {
        historyTask?.cancel()
        generation = nil
    }

    /// 主动关闭只投递一次，错误页同样可以退出。
    func close(onEvent: (PaywallSessionEvent) -> Void) {
        guard !isClosing else { return }
        historyTask?.cancel()
        isClosing = true
        generation = nil
        onEvent(.closed)
    }

    /// 已成功的交易终止当前交互，防止退场动画期间再次发起购买或挽留。
    private func receive(_ event: PaywallSessionEvent, token: UUID,
                         onEvent: (PaywallSessionEvent) -> Void) {
        guard generation == token, !isClosing else { return }
        switch event {
        case .purchaseFinished(_, .succeeded), .restoreFinished(.succeeded): isClosing = true
        default: break
        }
        onEvent(event)
    }
}
