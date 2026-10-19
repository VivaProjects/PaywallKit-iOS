import SwiftUI
import WebKit

/// 将一次 H5 加载会话绑定到 SwiftUI 的 WebView 生命周期。
struct WebPaywallContainer: UIViewRepresentable {
    @Environment(\.webPaywallSheetLayoutID) private var sheetLayoutID
    let document: WebPaywallDocument
    let storefrontGroup: String
    let host: PaywallHost
    let environment: WebPaywallEnvironmentConfiguration
    let custom: [String: WebPaywallJSONValue]
    let webViewCache: WebPaywallWebViewCache?
    let preparationDeadline: Date?
    let isPresented: Bool
    let onContentHeightChange: ((CGFloat) -> Void)?
    let onReady: () -> Void
    let onFailure: () -> Void
    let onTypedFailure: ((PaywallFailure) -> Void)?
    let onResourceSource: ((String) -> Void)?

    /// 每次挂载创建独立会话，避免旧页面的异步结果写入新页面。
    func makeCoordinator() -> WebPaywallCoordinator {
        if let cached = webViewCache?.coordinator(for: document,
                                                   storefrontGroup: storefrontGroup,
                                                   environment: environment,
                                                   custom: custom) {
            cached.presentationDeadline = preparationDeadline
            return cached
        }
        let coordinator = WebPaywallCoordinator(document: document,
                                                storefrontGroup: storefrontGroup,
                                                environmentConfiguration: environment,
                                                custom: custom)
        coordinator.webViewCache = webViewCache
        coordinator.presentationDeadline = preparationDeadline
        return coordinator
    }

    /// 页面请求与商店查询同时启动，版本资源遵循 HTTP 缓存策略。
    func makeUIView(context: Context) -> WebPaywallViewportView {
        context.coordinator.setPresentationActive(isPresented)
        if let cached = webViewCache?.claim(coordinator: context.coordinator) {
            // claim 会恢复默认交互，内嵌隐藏宿主必须在 attach 前再次关闭。
            context.coordinator.setPresentationActive(isPresented)
            context.coordinator.attach(host: host, onReady: onReady, onFailure: onFailure,
                                       onContentHeightChange: onContentHeightChange, onTypedFailure: onTypedFailure,
                                       onResourceSource: onResourceSource)
            context.coordinator.beginPresentationDeadline()
            return WebPaywallViewportView(webView: cached, sheetLayoutID: sheetLayoutID)
        }
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "PaywallBridge")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WebPaywallWebViewFactory.make(configuration: configuration)
        webView.diagnosticEnvironment = environment.runtimeEnvironment.rawValue
        // 内容自适应 Sheet 保留系统表面，不用 WebView 默认白底遮挡。
        if onContentHeightChange != nil {
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
        }
        webView.navigationDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        context.coordinator.attach(host: host, onReady: onReady, onFailure: onFailure,
                                       onContentHeightChange: onContentHeightChange, onTypedFailure: onTypedFailure,
                                       onResourceSource: onResourceSource)
        webViewCache?.store(webView, coordinator: context.coordinator,
                            document: document, storefrontGroup: storefrontGroup,
                            environment: environment, custom: custom)
        // 总超时从请求之前开始，不能等 didFinish 才覆盖加载故障。
        context.coordinator.start(webView: webView)

        return WebPaywallViewportView(webView: webView, sheetLayoutID: sheetLayoutID)
    }

    func updateUIView(_ uiView: WebPaywallViewportView, context: Context) {
        uiView.configure(sheetLayoutID: sheetLayoutID)
        context.coordinator.updateHost(host)
        context.coordinator.setPresentationActive(isPresented)
    }

    /// 页面移除时取消加载任务并断开桥，晚到结果不得改变宿主界面。
    static func dismantleUIView(_ container: WebPaywallViewportView, coordinator: WebPaywallCoordinator) {
        let uiView = container.webView
        if coordinator.webViewCache?.release(uiView, coordinator: coordinator) == true { return }
        coordinator.stop()
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "PaywallBridge")
        uiView.navigationDelegate = nil
        uiView.stopLoading()
    }
}
