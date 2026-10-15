import SwiftUI

/// 隐藏准备与正式弹窗共享输入及 WebView，生命周期仅限这一次展示。
@MainActor
final class PaywallPreparedPage {
    private(set) var isCancelled = false
    let placement: PaywallPlacement
    let input: PaywallSessionInput
    let cache: WebPaywallWebViewCache

    init(placement: PaywallPlacement, input: PaywallSessionInput,
         retentionPolicy: WebPaywallWebViewCache.RetentionPolicy = .keepAfterDismissal,
         cache: WebPaywallWebViewCache? = nil) {
        self.cache = cache ?? WebPaywallWebViewCache(retentionPolicy: retentionPolicy)
        self.placement = placement
        self.input = input.forPlacement(placement.name)
    }

    /// 复用输入环境记录高层准备流程，不另设全局开关。
    func trace(_ event: String, _ detail: String = "") {
        WebPaywallDiagnostics.log(input.environment.runtimeEnvironment.rawValue, event,
            "placement=\(placement.name) document=\(input.document.documentId) \(detail)")
    }

    /// 正式接管前再次确认缓存未失效，禁止退回可见的加载页。
    var isReady: Bool {
        !isCancelled && cache.isReady(for: input.document, storefrontGroup: placement.name,
                      environment: input.environment, custom: input.custom)
    }
    /// 跳过或退场后禁止布局队列重新启动网页，已挂载缓存会在卸载时销毁。
    func cancel() {
        trace("prepared_page.cancel")
        isCancelled = true
        cache.destroy()
    }
}

private struct PaywallPreparedPageKey: EnvironmentKey {
    static let defaultValue: PaywallPreparedPage? = nil
}

extension EnvironmentValues {
    var paywallPreparedPage: PaywallPreparedPage? {
        get { self[PaywallPreparedPageKey.self] }
        set { self[PaywallPreparedPageKey.self] = newValue }
    }
}
