import UIKit
import WebKit

/// 拦截 H5 原生长按入口，并在显式测试环境记录挂载和视口变化。
final class WebPaywallDiagnosticWebView: WKWebView, WKUIDelegate {
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
        disableLongPressInteractions(in: self)
        trace("attached=\(window != nil) longPressPolicy=native.v2")
    }

    /// 限制动态安装的长按交互，并仅记录实际变化的布局。
    override func layoutSubviews() {
        super.layoutSubviews()
        // WebKit 可能在页面加载或缓存重新挂载后安装新的交互对象。
        disableLongPressInteractions(in: self)
        guard bounds != previousBounds || safeAreaInsets != previousInsets else { return }
        previousBounds = bounds
        previousInsets = safeAreaInsets
        trace("bounds=\(bounds) safeArea=\(safeAreaInsets)")
    }

    /// 在触摸分发前再次限制长按，覆盖首次触摸时才安装的系统手势。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let target = super.hitTest(point, with: event)
        if event?.type == .touches {
            disableLongPressInteractions(in: self)
        }
        return target
    }

    /// 拒绝文字编辑菜单中的复制、选择及查询等系统动作。
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }

    /// 单独拒绝原生图片和链接菜单，避免依赖 DOM 的 contextmenu。
    func webView(_ webView: WKWebView,
                 contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping @MainActor (UIContextMenuConfiguration?) -> Void) {
        completionHandler(nil)
    }

    /// 只关闭公开的长按与拖拽入口，保留点击和滚动手势及其原有代理。
    private func disableLongPressInteractions(in view: UIView) {
        // 系统文字选择、图片操作和拖拽可能安装在 WebKit 内容子视图上。
        for recognizer in view.gestureRecognizers ?? [] where recognizer is UILongPressGestureRecognizer {
            if recognizer.isEnabled { recognizer.isEnabled = false }
        }
        for case let interaction as UIDragInteraction in view.interactions {
            if interaction.isEnabled { interaction.isEnabled = false }
        }
        // 不依赖 WebKit 私有类名，也不删除系统手势或替换其代理。
        for child in view.subviews {
            disableLongPressInteractions(in: child)
        }
    }

    deinit {
        WebPaywallDiagnostics.log(diagnosticEnvironment, "webview.deinit",
                                 "webView=\(ObjectIdentifier(self))")
    }
}
