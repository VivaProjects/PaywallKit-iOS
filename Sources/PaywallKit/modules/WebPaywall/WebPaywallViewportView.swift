import WebKit

/// Sheet 确定视口后只做画面形变；配置或窗口尺寸变化才重新布局网页。
final class WebPaywallViewportView: UIView {
    let webView: WKWebView
    private var hasInitialLayout = false
    private var viewportEstablished = false
    private var sheetLayoutID: AnyHashable?
    private var windowSize = CGSize.zero
    private var pendingLayout: DispatchWorkItem?

    /// 缓存只持有 WebView，每次展示创建独立容器，不重载 H5。
    init(webView: WKWebView, sheetLayoutID: AnyHashable?) {
        self.webView = webView
        self.sheetLayoutID = sheetLayoutID
        super.init(frame: .zero)
        clipsToBounds = true
        webView.removeFromSuperview()
        webView.autoresizingMask = []
        webView.transform = .identity
        addSubview(webView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 离开窗口时取消延迟任务，防止旧容器改写已经被下一次展示接管的 WebView。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { pendingLayout?.cancel(); pendingLayout = nil }
    }

    /// 宿主只有改变真实 detent 配置时才解锁视口，不把普通 SwiftUI 更新当作重排请求。
    func configure(sheetLayoutID: AnyHashable?) {
        guard self.sheetLayoutID != sheetLayoutID else { return }
        self.sheetLayoutID = sheetLayoutID
        viewportEstablished = false
        pendingLayout?.cancel()
        setNeedsLayout()
    }

    /// 初始展示等待布局安定；之后拖动及松手仅改变画面变换，不改 WebView bounds。
    override func layoutSubviews() {
        super.layoutSubviews()
        pendingLayout?.cancel()
        guard let window, bounds.width > 0, bounds.height > 0 else { return }
        let actualWindowSize = window.bounds.size
        if !hasInitialLayout || webView.bounds.width != bounds.width || windowSize != actualWindowSize {
            hasInitialLayout = true
            windowSize = actualWindowSize
            viewportEstablished = false
            applyViewport()
        }
        alignRenderedViewport()
        if sheetLayoutID != nil && viewportEstablished { return }
        if viewportEstablished && webView.bounds.size == bounds.size { return }
        scheduleInitialViewport()
    }

    /// 延迟只用于初始布局或明确的配置变更，拖动停顿不会再次触发网页重排。
    private func scheduleInitialViewport() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.window != nil, self.webView.superview === self else { return }
            if self.webView.bounds.size != self.bounds.size { self.applyViewport() }
            self.viewportEstablished = true
            self.pendingLayout = nil
            (self.webView as? WebPaywallDiagnosticWebView)?.trace("established viewport=\(self.webView.bounds.size)")
        }
        pendingLayout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// 临时缩放已绘制表面以贴合上下边缘，不改变网页视口或 H5 滚动位置。
    private func alignRenderedViewport() {
        guard webView.bounds.height > 0 else { return }
        UIView.performWithoutAnimation {
            webView.transform = CGAffineTransform(scaleX: 1, y: bounds.height / webView.bounds.height)
            webView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    /// 稳定后清除临时形变并同步真实视口，文字和点击区域恢复正常布局。
    private func applyViewport() {
        backgroundColor = webView.underPageBackgroundColor
        (webView as? WebPaywallDiagnosticWebView)?.trace("apply viewport=\(bounds.size)")
        UIView.performWithoutAnimation {
            webView.transform = .identity
            webView.bounds = CGRect(origin: .zero, size: bounds.size)
            webView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }
}
