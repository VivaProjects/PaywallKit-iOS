import SwiftUI

/// 同步接管已经渲染的会话，首次可见帧直接创建缓存 WebView 的宿主。
@MainActor
struct PaywallSessionScreen: View {
    @StateObject private var model: PaywallSessionModel
    @State private var retryGeneration = 0
    @State private var contentHeight: CGFloat?
    @State private var recoveryTask: Task<Void, Never>?
    let isPresented: Bool
    let client: PaywallClient
    let placement: String
    let resolvedPlacement: PaywallPlacement?
    let preparedPage: PaywallPreparedPage?
    let validityIdentity: AnyHashable
    let cacheIdentity: AnyHashable
    let canDismiss: () -> Bool
    let copy: PaywallRuntimeCopy
    let prepare: (WebPaywallDocument) async throws -> PaywallSessionInput
    let openLegal: (PaywallHost.LegalRoute) -> Void
    let onEvent: (PaywallSessionEvent) -> Void

    init(client: PaywallClient, placement: String, resolvedPlacement: PaywallPlacement?,
         preparedPage: PaywallPreparedPage?, validityIdentity: AnyHashable, cacheIdentity: AnyHashable,
         isPresented: Bool, localPackages: PaywallLocalPackageStore?,
         canDismiss: @escaping () -> Bool, copy: PaywallRuntimeCopy,
         prepare: @escaping (WebPaywallDocument) async throws -> PaywallSessionInput,
         prepareCached: ((WebPaywallDocument) throws -> PaywallSessionInput)?,
         openLegal: @escaping (PaywallHost.LegalRoute) -> Void,
         onEvent: @escaping (PaywallSessionEvent) -> Void) {
        self.isPresented = isPresented
        self.client = client
        self.placement = placement
        self.resolvedPlacement = resolvedPlacement
        self.preparedPage = preparedPage
        self.validityIdentity = validityIdentity
        self.cacheIdentity = cacheIdentity
        self.canDismiss = canDismiss
        self.copy = copy
        self.prepare = prepare
        self.openLegal = openLegal
        self.onEvent = onEvent
        _model = StateObject(wrappedValue: PaywallSessionModel(
            prepared: preparedPage,
            fallbackContext: localPackages.map { PaywallFallbackContext(placement: placement, store: $0) }
                ?? resolvedPlacement?.fallbackContext ?? client.makeFallbackContext(placement),
            cached: {
                guard !client.isPlacementDisabled(placement), let prepareCached else { return nil }
                return client.preparedCachedPage(for: placement, identity: cacheIdentity,
                                                resolved: resolvedPlacement, prepare: prepareCached)
            }, onEvent: onEvent
        ))
    }

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                statusView(error: nil)
            case let .failed(message):
                statusView(error: message)
            case let .ready(session):
                page(session)
            }
        }
        .preference(key: PaywallContentHeightKey.self, value: contentHeight)
        .interactiveDismissDisabled(!canDismiss() || resolvedPlacement?.presentation == .halfSheetLocked)
        .task(id: retryGeneration) {
            await model.load(client: client, placement: placement, resolved: resolvedPlacement,
                             cacheIdentity: cacheIdentity, prepared: retryGeneration == 0 ? preparedPage : nil,
                             prepare: prepare, onEvent: onEvent)
        }
        .onChange(of: validityIdentity) { _ in
            recoveryTask?.cancel()
            contentHeight = nil
            client.invalidatePage(for: placement)
            model.fail("The product catalog or paywall mode changed.", onEvent: onEvent)
        }
        .onDisappear { recoveryTask?.cancel(); model.detach() }
    }

    /// SDK 创建 Host，业务只消费语义事件；底层 WebPaywallView API 保持兼容。
    private func page(_ session: PaywallSessionModel.Session) -> some View {
        WebPaywallView(
            document: session.input.document, storefrontGroup: placement,
            host: PaywallHost(bridge: session.bridge, allowsDismiss: true,
                             image: { _ in nil }, openLegal: openLegal,
                             dismiss: close, track: { _ in }, copy: copy),
            environment: session.input.environment, custom: session.input.custom,
            webViewCache: session.cache,
            preparationDeadline: model.deadline, isPresented: isPresented,
            onContentHeightChange: { contentHeight = $0 },
            onReady: { model.ready(session: session, client: client, onEvent: onEvent) },
            onFailure: { failure in
                guard canDismiss() else { model.fail(failure.rawValue, onEvent: onEvent); return }
                recoveryTask?.cancel()
                recoveryTask = Task {
                    await model.recover(failure, sessionID: session.id, client: client, placement: placement,
                                        cacheIdentity: cacheIdentity, prepare: prepare, onEvent: onEvent)
                }
            },
            onResourceSource: { model.resourceSource($0, session: session) }
        ) {
            statusView(error: copy.unavailable)
        }
        .id(session.id)
        .ignoresSafeArea(.container, edges: .all)
    }

    /// 错误内容允许随字体增长并滚动，按钮不使用固定文字高度。
    private func statusView(error: String?) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 20) {
                    if let error {
                        Text(copy.unavailable).multilineTextAlignment(.center)
                        #if DEBUG
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                        #endif
                        retryButton
                    } else {
                        ProgressView(copy.loading)
                    }
                    Button(copy.close, action: close).disabled(!canDismiss())
                }
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
    }

    /// 原生主操作在新系统使用系统玻璃，旧系统保留原生突出按钮。
    @ViewBuilder
    private var retryButton: some View {
        if #available(iOS 26.0, *) {
            Button(copy.retry, action: retry).buttonStyle(.glassProminent)
        } else {
            Button(copy.retry, action: retry).buttonStyle(.borderedProminent)
        }
    }

    /// 重试沿用本次点位快照，只销毁失败网页并重新创建业务会话。
    private func retry() {
        recoveryTask?.cancel()
        preparedPage?.cancel()
        client.invalidatePage(for: placement)
        contentHeight = nil
        onEvent(.retrying)
        retryGeneration += 1
    }

    /// 主动关闭只发送关闭事件，不与购买成功共用回调。
    private func close() {
        guard canDismiss() else { return }
        recoveryTask?.cancel()
        model.close(onEvent: onEvent)
    }
}
