import SwiftUI

/// 在页面创建前固定本次展示方式；原生页面继续沿用原有全屏路径。
@MainActor
private struct PaywallPresentationModifier<Item: Identifiable, Destination: View>: ViewModifier {
    private struct LoadIdentity: Hashable {
        let itemID: Item.ID?
        let retry: Int
    }

    @Binding var item: Item?
    let client: PaywallClient
    let placement: (Item) -> String?
    let skipsMissingPlacement: Bool
    let waitsForReady: (Item) -> Bool
    let prepareForPresentation: ((Item, WebPaywallDocument) async throws -> PaywallSessionInput)?
    let preloadedPage: ((Item) -> PaywallPreload?)?
    let canPresentPrepared: () -> Bool
    let preparationIdentity: AnyHashable
    let onPresented: (Item) -> Void
    let onDismiss: () -> Void
    let destination: (Item) -> Destination
    @State private var activeItem: Item?
    @State private var mode = WebPaywallConfiguration.Presentation.fullScreen
    @State private var resolvedPlacement: PaywallPlacement?
    @State private var requestID: Item.ID?
    @State private var isPushed = false
    @State private var hasRequest = false
    // 提交系统展示后持续保留到退场完成，避免自身弹窗被当成外部占用。
    @State private var hasCommittedPresentation = false
    @State private var loadError: String?
    @State private var retryGeneration = 0
    @State private var sheetWidth: CGFloat?
    @State private var contentHeight: CGFloat?
    @State private var lastReportedHeight: CGFloat?
    @State private var pendingHeightUpdate: Task<Void, Never>?
    @State private var preparedPage: PaywallPreparedPage?
    @State private var preparingItem: Item?
    @State private var preparationToken: UUID?

    func body(content: Content) -> some View {
        content
            .background { preparationView }
            .overlay { loadingOverlay }
            .fullScreenCover(item: modalBinding(sheet: false), onDismiss: finish) { value in
                paywall(value)
            }
            .sheet(item: modalBinding(sheet: true), onDismiss: finish) { value in
                paywall(value)
                    .background {
                        GeometryReader { geometry in
                            Color.clear
                                .onAppear { captureSheetWidth(geometry.size.width) }
                                .onChange(of: geometry.size.width) { captureSheetWidth($0) }
                        }
                    }
                    .environment(\.webPaywallSheetLayoutID, AnyHashable(sheetDetents))
                    .presentationDetents(sheetDetents)
                    .onPreferenceChange(PaywallContentHeightKey.self) { scheduleContentHeight($0) }
                    .presentationDragIndicator(mode == .halfSheetLocked ? .hidden : .visible)
                    .interactiveDismissDisabled(mode == .halfSheetLocked)
            }
            .overlay { pushPresentation }
            .task(id: LoadIdentity(itemID: item?.id, retry: retryGeneration)) {
                await prepare()
            }
            .task(id: preparationToken) { await enforcePreparationDeadline() }
            .onChange(of: canPresentPrepared()) { allowed in
                if !allowed && hasRequest && !hasCommittedPresentation { finish() }
            }
            .onChange(of: preparationIdentity) { _ in
                if preparationToken != nil { finish() }
            }
            .onDisappear {
                if preparationToken != nil { finish() }
            }
            .alert("Unable to load subscriptions.", isPresented: errorBinding) {
                Button("Retry") { loadError = nil; retryGeneration += 1 }
                Button("Close", role: .cancel, action: finish)
            } message: {
                Text(loadError ?? "")
            }
    }

    /// Push 在独立覆盖层中拥有自己的导航栈，不向 Plan 等业务路径注册目的页。
    @ViewBuilder
    private var pushPresentation: some View {
        if mode == .push, let value = activeItem {
            NavigationStack {
                Color.clear
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(isPresented: $isPushed) {
                        paywall(value)
                            .toolbar(.hidden, for: .navigationBar)
                            .onDisappear { if !isPushed { finish() } }
                    }
            }
            .onAppear {
                // 只在独立宿主挂载时推进；返回到空根页面时不得重新打开付费墙。
                isPushed = true
            }
        }
    }

    /// 所有局部弹层优先展示完整内容；未上报高度时使用系统最大可用高度。
    private var sheetDetents: Set<PresentationDetent> {
        contentHeight.map { [.height($0)] } ?? [.large]
    }

    /// 仅真实宽度变化才允许重新定高，系统竖向拖动不解锁本次结果。
    private func captureSheetWidth(_ width: CGFloat) {
        guard width.isFinite, width > 0, sheetWidth != width else { return }
        if sheetWidth != nil {
            pendingHeightUpdate?.cancel()
            contentHeight = nil
            scheduleContentHeight(lastReportedHeight)
        }
        sheetWidth = width
    }

    /// 每次展示只接受首次稳定的内容高度；安全区由系统计入，避免重复计算。
    private func scheduleContentHeight(_ height: CGFloat?) {
        guard let height, height.isFinite, height > 0 else { return }
        lastReportedHeight = height
        guard activeItem != nil, contentHeight == nil else { return }
        pendingHeightUpdate?.cancel()
        pendingHeightUpdate = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, activeItem != nil, contentHeight == nil else { return }
            preparedPage?.trace("presentation.detent", "height=\(height)")
            contentHeight = height
            pendingHeightUpdate = nil
        }
    }

    /// 请求期间提供取消入口，防止重复点击或长时间无反馈。
    @ViewBuilder
    private var loadingOverlay: some View {
        if let item, !waitsForReady(item), activeItem == nil && loadError == nil
            && !client.hasConfiguration {
            ZStack {
                Color.black.opacity(0.15).ignoresSafeArea()
                VStack(spacing: 16) {
                    ProgressView("Loading subscriptions…")
                    Button("Close", action: finish)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    /// 冻结配置传入 H5，购买、关闭等回调仍由原页面维护。
    private func paywall(_ value: Item) -> some View {
        destination(value)
            .environment(\.paywallPlacement, resolvedPlacement)
            .environment(\.paywallPreparedPage, preparedPage)
            .onAppear { onPresented(value) }
    }

    /// 只让所选的系统弹层消费本次请求，避免多个容器同时打开。
    private func modalBinding(sheet: Bool) -> Binding<Item?> {
        Binding(
            get: {
                let isSheet = mode == .halfSheet || mode == .halfSheetLocked
                return mode != .push && isSheet == sheet ? activeItem : nil
            },
            set: { if $0 == nil { activeItem = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })
    }

    /// 请求替换或取消时丢弃晚到结果；后台准备不创建业务页面或加载遮罩。
    private func prepare() async {
        guard let value = item else {
            if isPushed { isPushed = false }
            else if activeItem != nil { activeItem = nil }
            else if hasRequest && !hasCommittedPresentation { finish() }
            return
        }
        guard activeItem == nil, !hasCommittedPresentation else { return }
        let token = beginRequest(value)
        if let preloadedPage {
            presentPreloaded(value, preload: preloadedPage(value))
            return
        }
        do {
            if !canPresentPrepared() { finish(); return }
            let selected = try await resolve(value)
            try Task.checkCancellation()
            guard hasRequest, item?.id == value.id else { return }
            guard canPresentPrepared() else { finish(); return }
            resolvedPlacement = selected
            mode = selected?.presentation ?? .fullScreen
            if waitsForReady(value) {
                guard let selected, let prepareForPresentation else {
                    throw WebPaywallError.invalidDocument
                }
                let input = try await prepareForPresentation(value, selected.document)
                try Task.checkCancellation()
                guard preparationToken == token, item?.id == value.id else { return }
                preparingItem = value
                preparedPage = PaywallPreparedPage(placement: selected, input: input)
            } else {
                hasCommittedPresentation = true
                activeItem = value
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, hasRequest, item?.id == value.id else { return }
            // 被动冷启动失败直接消费本次机会；主动入口沿用重试提示。
            if waitsForReady(value) || (error as? PaywallFailure) == .disabled { finish() }
            else { loadError = error.localizedDescription }
        }
    }

    /// 每次请求重置准备状态；原有冷启动期限仍覆盖解析、商品与首屏渲染。
    private func beginRequest(_ value: Item) -> UUID {
        preparedPage?.cancel()
        preparedPage = nil
        preparingItem = nil
        hasRequest = true
        requestID = value.id
        let token = UUID()
        preparationToken = preloadedPage == nil && waitsForReady(value) ? token : nil
        return token
    }

    /// 接管首墙期间已准备的页面；缺失或失效时直接结束，不回退到可见加载。
    private func presentPreloaded(_ value: Item, preload: PaywallPreload?) {
        guard canPresentPrepared(), let key = placement(value),
              let page = preload?.consume(client: client, placement: key) else {
            preload?.cancel()
            finish()
            return
        }
        resolvedPlacement = page.placement
        mode = page.placement.presentation
        preparedPage = page
        seedContentHeight(from: page)
        hasCommittedPresentation = true
        activeItem = value
    }

    /// 配置快照只解析一次，正式页面复用同一份展示方式与商品绑定。
    private func resolve(_ value: Item) async throws -> PaywallPlacement? {
        guard let key = placement(value) else { return nil }
        let selected: PaywallPlacement?
        let context = client.makeFallbackContext(key)
        if context.store != nil {
            selected = try await client.resolveForPresentation(key, context: context)
        } else if let cached = client.cachedPlacement(key) { selected = cached }
        else { selected = try await client.resolve(key) }
        try Task.checkCancellation()
        guard hasRequest, item?.id == value.id else { throw CancellationError() }
        guard let selected else {
            if skipsMissingPlacement { finish(); return nil }
            throw WebPaywallError.invalidDocument
        }
        return selected
    }

    /// 背景保留真实布局空间但完全透明，触摸和辅助功能不会进入待展示网页。
    @ViewBuilder
    private var preparationView: some View {
        if let page = preparedPage, let value = preparingItem, let token = preparationToken {
            PaywallPreparationView(page: page,
                                   onReady: { presentPrepared(value, page: page, token: token) },
                                   onFailure: { if preparationToken == token { finish() } })
                .id(token)
                .ignoresSafeArea(.container, edges: .all)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// 只有当前请求仍有展示资格且缓存可复用时才打开系统弹窗。
    private func presentPrepared(_ value: Item, page: PaywallPreparedPage, token: UUID) {
        guard preparationToken == token, hasRequest, item?.id == value.id else { return }
        guard canPresentPrepared(), page.isReady else { finish(); return }
        preparationToken = nil
        preparingItem = nil
        seedContentHeight(from: page)
        hasCommittedPresentation = true
        activeItem = value
    }

    /// 先恢复预渲染高度再打开 Sheet，避免先以 large 出现后缩小造成闪动。
    private func seedContentHeight(from page: PaywallPreparedPage) {
        guard mode == .halfSheet || mode == .halfSheetLocked,
              let height = page.cache.preparedContentHeight,
              height.isFinite, height > 0 else { return }
        contentHeight = height
        lastReportedHeight = height
    }

    /// 超时任务可随取消和就绪自动结束，不因不可见 WebKit 暂停绘制而永久挂起。
    private func enforcePreparationDeadline() async {
        guard let token = preparationToken else { return }
        do { try await Task.sleep(nanoseconds: 12_000_000_000) }
        catch { return }
        guard preparationToken == token else { return }
        finish()
    }

    /// 退场后统一清理请求，并且只触发一次宿主接续回调。
    private func finish() {
        guard hasRequest else { return }
        pendingHeightUpdate?.cancel()
        pendingHeightUpdate = nil
        // 未弹出就跳过不属于退场，不能触发宿主的挽留或关闭其他弹窗。
        let skippedPreparation = preparationToken != nil
        hasRequest = false
        hasCommittedPresentation = false
        preparationToken = nil
        preparingItem = nil
        preparedPage?.cancel()
        preparedPage = nil
        activeItem = nil
        isPushed = false
        contentHeight = nil
        lastReportedHeight = nil
        sheetWidth = nil
        resolvedPlacement = nil
        loadError = nil
        if item?.id == requestID { item = nil }
        requestID = nil
        if !skippedPreparation { onDismiss() }
    }
}

extension View {
    /// 按下发配置展示支付墙；被动入口可选择就绪后展示，跳过时仅清空 item。
    /// waitsForReady 需搭配 prepareForPresentation；预加载句柄优先且只接管一次。
    /// preloadedPage 未就绪时直接清空请求并调用 onDismiss，供宿主释放接续流程。
    @MainActor
    public func paywallHost<Item: Identifiable, Destination: View>(
        client: PaywallClient,
        item: Binding<Item?>,
        placement: @escaping (Item) -> String?,
        skipsMissingPlacement: Bool = false,
        waitsForReady: @escaping (Item) -> Bool = { _ in false },
        prepareForPresentation: ((Item, WebPaywallDocument) async throws -> PaywallSessionInput)? = nil,
        preloadedPage: ((Item) -> PaywallPreload?)? = nil,
        canPresentPrepared: @escaping () -> Bool = { true },
        preparationIdentity: AnyHashable = 0,
        onPresented: @escaping (Item) -> Void = { _ in },
        onDismiss: @escaping () -> Void = {},
        @ViewBuilder content: @escaping (Item) -> Destination
    ) -> some View {
        modifier(PaywallPresentationModifier(
            item: item, client: client, placement: placement, skipsMissingPlacement: skipsMissingPlacement,
            waitsForReady: waitsForReady, prepareForPresentation: prepareForPresentation,
            preloadedPage: preloadedPage,
            canPresentPrepared: canPresentPrepared, preparationIdentity: preparationIdentity,
            onPresented: onPresented, onDismiss: onDismiss, destination: content
        ))
    }
}
