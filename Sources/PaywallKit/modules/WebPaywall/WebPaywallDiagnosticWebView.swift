import WebKit

/// 在显式测试环境记录挂载和视口变化，区分页面重建与系统拖动重排。
final class WebPaywallDiagnosticWebView: WKWebView {
    var diagnosticEnvironment = "production"
    private var previousBounds = CGRect.zero
    private var previousInsets = UIEdgeInsets.zero

    /// 同一对象标识贯穿挂载和布局，不包含商品或用户数据。
    func trace(_ message: String) {
        WebPaywallDiagnostics.log(diagnosticEnvironment, "webview.layout",
            "webView=\(ObjectIdentifier(self)) \(message)")
    }

    /// 记录实际窗口挂载状态。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        trace("attached=\(window != nil)")
    }

    /// 仅记录实际变化的布局，避免重复布局调用淹没诊断信息。
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds != previousBounds || safeAreaInsets != previousInsets else { return }
        previousBounds = bounds
        previousInsets = safeAreaInsets
        trace("bounds=\(bounds) safeArea=\(safeAreaInsets)")
    }

    deinit {
        WebPaywallDiagnostics.log(diagnosticEnvironment, "webview.deinit",
                                 "webView=\(ObjectIdentifier(self))")
    }
}
