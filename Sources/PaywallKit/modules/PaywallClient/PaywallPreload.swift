import Combine
import Foundation

/// 单次流程持有的预加载句柄；准备完成后等待宿主明确接管，不自动展示。
@MainActor
public final class PaywallPreload: ObservableObject {
    private(set) var page: PaywallPreparedPage?
    @Published public private(set) var isPreparing = false
    private var generation: UUID?
    private var consumed = false
    private var preparationTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private weak var client: PaywallClient?

    public init() {}

    public var isReady: Bool { !consumed && page?.isReady == true }

    /// 从配置解析开始计时；每次启动都会取消上一次流程，晚到结果不能写回。
    public func start(client: PaywallClient, placement: String,
                      prepare: @escaping @MainActor (WebPaywallDocument) async throws -> PaywallSessionInput) {
        cancel()
        self.client = client
        let token = UUID()
        generation = token
        consumed = false
        isPreparing = true
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 12_000_000_000) }
            catch { return }
            guard self?.generation == token, self?.isPreparing == true else { return }
            self?.page?.trace("preload.timeout")
            self?.cancel()
        }
        preparationTask = Task { [weak self] in
            do {
                guard let selected = try await client.resolve(placement) else {
                    if self?.generation == token { self?.cancel() }
                    return
                }
                try Task.checkCancellation()
                let input = try await prepare(selected.document)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.objectWillChange.send()
                self.page = PaywallPreparedPage(placement: selected, input: input,
                                               retentionPolicy: .destroyAfterDismissal)
                self.page?.trace("preload.prepared")
                self.preparationTask = nil
            } catch {
                if self?.generation == token { self?.cancel() }
            }
        }
    }

    /// 未展示页面立即销毁；已挂载页面标记为卸载时释放，不中断退场动画。
    public func cancel() {
        page?.trace("preload.cancel")
        generation = nil
        historyTask?.cancel()
        historyTask = nil
        preparationTask?.cancel()
        preparationTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        page?.cancel()
        page = nil
        isPreparing = false
    }

    /// 首屏回执停止准备期限，等待用户关闭首墙期间不继续计时。
    func ready(_ prepared: PaywallPreparedPage) {
        guard page === prepared, !consumed, prepared.isReady else { return }
        prepared.trace("preload.ready")
        if let client {
            historyTask = Task {
                await client.recordSuccess(prepared.placement, document: prepared.input.document,
                                           environment: prepared.input.environment.runtimeEnvironment.rawValue)
            }
        }
        deadlineTask?.cancel()
        deadlineTask = nil
        isPreparing = false
    }

    /// 失败回调仅能清理创建它的那一页。
    func failed(_ prepared: PaywallPreparedPage) {
        guard page === prepared, !consumed else { return }
        prepared.trace("preload.failed")
        cancel()
    }

    /// 一个句柄只能交给同一 Client、同一点位的展示宿主一次。
    func consume(client: PaywallClient, placement: String) -> PaywallPreparedPage? {
        guard isReady, let page, page.placement.clientID == client.id,
              page.placement.name == placement else { return nil }
        page.trace("preload.consume")
        consumed = true
        self.page = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        isPreparing = false
        return page
    }

    deinit {
        historyTask?.cancel()
        historyTask = nil
        preparationTask?.cancel()
        deadlineTask?.cancel()
        // SwiftUI 移除整个流程时也释放尚未接管的页面。
        let abandonedPage = page
        Task { @MainActor in abandonedPage?.cancel() }
    }
}
