import SwiftUI

/// 在根视图后台预热常驻点位；正式展示仍创建独立的购买桥和业务回调。
@MainActor
public struct PaywallCachedPreloadView: View {
    private struct Identity: Hashable {
        let clientID: UUID
        let placement: String
        let cacheIdentity: AnyHashable
        let enabled: Bool
    }

    private let client: PaywallClient
    private let placement: String
    private let cacheIdentity: AnyHashable
    private let enabled: Bool
    private let prepare: (WebPaywallDocument) async throws -> PaywallSessionInput
    private let onFailure: (Error) -> Void
    @State private var page: PaywallPreparedPage?
    @State private var historyTask: Task<Void, Never>?

    public init(client: PaywallClient, placement: String, cacheIdentity: AnyHashable,
                enabled: Bool = true,
                prepare: @escaping (WebPaywallDocument) async throws -> PaywallSessionInput,
                onFailure: @escaping (Error) -> Void = { _ in }) {
        self.client = client
        self.placement = placement
        self.cacheIdentity = cacheIdentity
        self.enabled = enabled
        self.prepare = prepare
        self.onFailure = onFailure
    }

    public var body: some View {
        ZStack {
            // 空闲时也保留实体视图，确保 task 启动并获得根容器尺寸。
            Color.clear
            if let page {
                PaywallPreparationView(page: page,
                                       onReady: { recordSuccess(page); finish(page) },
                                       onFailure: {
                                           finish(page)
                                           onFailure(NSError(domain: "PaywallPreload", code: 1,
                                               userInfo: [NSLocalizedDescriptionKey:
                                                   "Preload failed before the first frame was ready: \(placement)"]))
                                       })
                    .id(ObjectIdentifier(page))
            }
        }
        .ignoresSafeArea(.container, edges: .all)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onDisappear { historyTask?.cancel() }
        .task(id: Identity(clientID: client.id, placement: placement,
                           cacheIdentity: cacheIdentity, enabled: enabled)) {
            await warmCache()
        }
    }

    /// 仅常驻点位共享缓存；身份变化由 Client 释放旧会话，取消结果不写回。
    private func warmCache() async {
        historyTask?.cancel()
        page = nil
        guard enabled else {
            client.invalidatePage(for: placement)
            return
        }
        // 在异步解析之前更新缓存身份，旧商品或权益不能继续复用。
        guard let cache = client.pageCache(for: placement, identity: cacheIdentity) else { return }
        do {
            // 本地点位与正式展示使用同一包；不能预热远端页面再展示本地版本。
            let context = client.makeFallbackContext(placement)
            let selected: PaywallPlacement
            if context.local {
                selected = try await client.resolveForPresentation(placement, context: context)
            } else {
                guard let remote = try await client.resolve(placement) else { return }
                selected = remote
            }
            try Task.checkCancellation()
            let input = try await prepare(selected.document)
            try Task.checkCancellation()
            page = PaywallPreparedPage(placement: selected, input: input, cache: cache)
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { onFailure(error) }
        }
    }

    /// 只有首屏真正就绪才归档，预加载失败不改变最近成功版本。
    private func recordSuccess(_ prepared: PaywallPreparedPage) {
        guard page === prepared, prepared.isReady else { return }
        historyTask?.cancel()
        historyTask = Task {
            await client.recordSuccess(prepared.placement, document: prepared.input.document,
                                           environment: prepared.input.environment.runtimeEnvironment.rawValue)
        }
    }

    /// 只卸下隐藏容器；缓存交由 Client 持有，不销毁已经被正式页面接管的网页。
    private func finish(_ prepared: PaywallPreparedPage) {
        guard page === prepared else { return }
        #if DEBUG
        print("[PaywallPreload] placement=\(placement) ready=\(prepared.isReady)")
        #endif
        page = nil
    }
}
