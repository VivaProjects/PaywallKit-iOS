import Foundation
import WebKit

/// 宿主持有的单页 WebView 缓存；弹窗和宿主模型仍按每次展示创建。
@MainActor
public final class WebPaywallWebViewCache {
    public enum RetentionPolicy {
        case keepAfterDismissal
        case destroyAfterDismissal
    }

    private struct Key: Equatable {
        let documentId: String
        let revision: Int?
        let pageURL: URL
        let catalogKey: String
        let productRefs: [String]
        let initialProductRef: String
        let storefrontGroup: String
        let environmentConfiguration: WebPaywallEnvironmentConfiguration
        let custom: [String: WebPaywallJSONValue]

        init(document: WebPaywallDocument, storefrontGroup: String,
             environmentConfiguration: WebPaywallEnvironmentConfiguration,
             custom: [String: WebPaywallJSONValue]) {
            documentId = document.documentId
            revision = document.revision
            pageURL = document.pageURL
            catalogKey = document.catalogKey
            productRefs = document.productRefs
            initialProductRef = document.initialProductRef
            self.storefrontGroup = storefrontGroup
            self.environmentConfiguration = environmentConfiguration
            self.custom = custom
        }
    }

    private struct Entry {
        let key: Key
        let webView: WKWebView
        let coordinator: WebPaywallCoordinator
        var mounted: Bool
    }

    private var entry: Entry?
    private let retentionPolicy: RetentionPolicy
    private var destroyWhenUnmounted = false

    public init(retentionPolicy: RetentionPolicy = .keepAfterDismissal) {
        self.retentionPolicy = retentionPolicy
    }

    /// 预渲染已测得的正文高度，供正式 Sheet 在首帧确定尺寸。
    var preparedContentHeight: CGFloat? { entry?.coordinator.contentHeight }

    /// 主动取消预加载并释放空闲页面；已挂载的页面在 SwiftUI 卸载时释放。
    public func destroy() {
        guard let entry else { return }
        entry.coordinator.trace("cache.destroy_requested", "mounted=\(entry.mounted)")
        if entry.mounted {
            destroyWhenUnmounted = true
        } else {
            clear()
        }
    }

    /// 提前加载网页与商品；屏幕外暂停的首屏回执在正式展示时继续等待。
    public func preload(document: WebPaywallDocument, storefrontGroup: String,
                        host: PaywallHost,
                        environment: WebPaywallEnvironmentConfiguration = .init(),
                        custom: [String: WebPaywallJSONValue] = [:],
                        onFailure: (() -> Void)? = nil,
                        onReady: (() -> Void)? = nil) {
        let key = Key(document: document, storefrontGroup: storefrontGroup,
                      environmentConfiguration: environment, custom: custom)
        if let entry, entry.key == key, entry.coordinator.isReusable {
            entry.coordinator.trace("preload.reuse", "ready=\(entry.coordinator.isReady)")
            if entry.coordinator.isReady { onReady?() }
            return
        }
        if entry?.mounted == true {
            entry?.coordinator.trace("preload.skipped", "reason=mounted")
            return
        }
        clear()

        let (webView, coordinator) = makePreloadedWebView(
            document: document, storefrontGroup: storefrontGroup, environment: environment, custom: custom)
        coordinator.attach(host: host, onReady: { [weak self, weak coordinator] in
            guard let self, let coordinator,
                  self.entry?.coordinator === coordinator else { return }
            coordinator.trace("preload.ready")
            coordinator.detach()
            self.entry?.webView.removeFromSuperview()
            onReady?()
        }, onFailure: { [weak self, weak coordinator] in
            guard let self, let coordinator,
                  self.entry?.coordinator === coordinator else { return }
            coordinator.trace("preload.failed")
            self.clear()
            onFailure?()
        })
        entry = Entry(key: key, webView: webView, coordinator: coordinator, mounted: false)
        coordinator.trace("preload.start")
        coordinator.start(webView: webView, preloading: true)

    }

    /// 缓存与隐藏准备共用受限桥，预加载期间禁止交易和页面路由。
    private func makePreloadedWebView(
        document: WebPaywallDocument, storefrontGroup: String,
        environment: WebPaywallEnvironmentConfiguration, custom: [String: WebPaywallJSONValue]
    ) -> (WKWebView, WebPaywallCoordinator) {
        let coordinator = WebPaywallCoordinator(document: document,
                                                storefrontGroup: storefrontGroup,
                                                environmentConfiguration: environment,
                                                custom: custom)
        coordinator.webViewCache = self
        coordinator.allowsActions = false
        let controller = WKUserContentController()
        controller.add(coordinator, name: "PaywallBridge")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WebPaywallDiagnosticWebView(frame: .zero, configuration: configuration)
        webView.diagnosticEnvironment = environment.runtimeEnvironment.rawValue
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false

        return (webView, coordinator)
    }

    /// 隐藏准备使用宿主真实尺寸参与布局，避免零尺寸页面停在首屏回执之前。
    func mountPreload(in container: UIView) {
        guard let entry, !entry.mounted, !entry.coordinator.isReady else { return }
        entry.coordinator.trace("preload.mount")
        entry.coordinator.requiresRenderReady = true
        entry.webView.frame = container.bounds
        entry.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(entry.webView)
        entry.coordinator.beginPresentationDeadline()
    }

    /// 只在相同文档、商品目录和店面中复用已完成的页面状态。
    public func isReady(for document: WebPaywallDocument, storefrontGroup: String,
                        environment: WebPaywallEnvironmentConfiguration = .init(),
                        custom: [String: WebPaywallJSONValue] = [:]) -> Bool {
        let key = Key(document: document, storefrontGroup: storefrontGroup,
                      environmentConfiguration: environment, custom: custom)
        return entry?.key == key && entry?.mounted == false &&
            entry?.coordinator.isReady == true
    }

    /// 与当前缓存不匹配时清除旧页，避免复用旧页面版本或商品目录。
    func coordinator(for document: WebPaywallDocument,
                     storefrontGroup: String,
                     environment: WebPaywallEnvironmentConfiguration,
                     custom: [String: WebPaywallJSONValue]) -> WebPaywallCoordinator? {
        let key = Key(document: document, storefrontGroup: storefrontGroup,
                      environmentConfiguration: environment, custom: custom)
        guard let entry else {
            WebPaywallDiagnostics.log(environment.runtimeEnvironment.rawValue, "cache.miss", "placement=\(environment.placement) document=\(document.documentId)")
            return nil
        }
        guard entry.key == key, !entry.mounted, entry.coordinator.isReusable else {
            entry.coordinator.trace("cache.mismatch", "sameKey=\(entry.key == key) mounted=\(entry.mounted) reusable=\(entry.coordinator.isReusable)")
            if !entry.mounted { clear() }
            return nil
        }
        entry.coordinator.trace("cache.hit")
        return entry.coordinator
    }

    /// 缓存页重新交给新的 UIViewRepresentable，由新弹窗重绑回调。
    func claim(coordinator: WebPaywallCoordinator) -> WKWebView? {
        guard var entry, !entry.mounted, entry.coordinator === coordinator else { return nil }
        coordinator.trace("cache.claim")
        entry.mounted = true
        entry.coordinator.allowsActions = true
        self.entry = entry
        return entry.webView
    }

    /// 首次创建后由缓存持有页面；弹窗销毁不会释放 WebKit 文档。
    func store(_ webView: WKWebView, coordinator: WebPaywallCoordinator,
               document: WebPaywallDocument, storefrontGroup: String,
               environment: WebPaywallEnvironmentConfiguration,
               custom: [String: WebPaywallJSONValue]) {
        coordinator.trace("cache.store")
        entry = Entry(key: Key(document: document, storefrontGroup: storefrontGroup,
                               environmentConfiguration: environment, custom: custom),
                      webView: webView, coordinator: coordinator, mounted: true)
    }

    /// 正常关闭只解除宿主引用；故障页面立即清理，不作为热缓存。
    func release(_ webView: WKWebView, coordinator: WebPaywallCoordinator) -> Bool {
        guard var entry, entry.webView === webView,
              entry.coordinator === coordinator else { return false }
        coordinator.trace("cache.release", "destroyRequested=\(destroyWhenUnmounted) policy=\(retentionPolicy) reusable=\(coordinator.isReusable)")
        if destroyWhenUnmounted || retentionPolicy == .destroyAfterDismissal {
            clear()
            return false
        }
        guard coordinator.isReusable else { clear(); return false }
        entry.mounted = false
        self.entry = entry
        coordinator.trace("cache.retained")
        coordinator.detach()
        return true
    }

    /// 清理不再适用的会话和桥，防止 WebView 与旧宿主互相持有。
    private func clear() {
        guard let entry else { return }
        entry.coordinator.trace("cache.clear")
        entry.coordinator.stop()
        if !entry.mounted { entry.webView.removeFromSuperview() }
        entry.webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "PaywallBridge")
        entry.webView.navigationDelegate = nil
        self.entry = nil
        destroyWhenUnmounted = false
    }
}
