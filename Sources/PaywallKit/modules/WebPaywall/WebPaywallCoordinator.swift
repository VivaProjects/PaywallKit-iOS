import Foundation
import StoreKit
import WebKit

/// 管理页面声明商品后的查询、桥接握手和单次展示的取消边界。
@MainActor
final class WebPaywallCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let document: WebPaywallDocument
    private let storefrontGroup: String
    private let environmentConfiguration: WebPaywallEnvironmentConfiguration
    private let custom: [String: WebPaywallJSONValue]
    private var host: PaywallHost?
    private var onContentHeightChange: ((CGFloat) -> Void)?
    private(set) var contentHeight: CGFloat?
    private var onReady: (() -> Void)?
    private var onFailure: (() -> Void)?
    private var onTypedFailure: ((PaywallFailure) -> Void)?
    private var queryingProducts = false
    private var resourceSource = "remote"
    private var onResourceSource: ((String) -> Void)?
    weak var webViewCache: WebPaywallWebViewCache?
    private let sessionID = UUID().uuidString
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private weak var webView: WKWebView?
    private var products: [String: PaywallStoreProduct] = [:]
    private var environment: WebPaywallEnvironment?
    private var active = true
    private var attached = false
    private var attachmentRevision = 0
    private var bridgeReady = false
    private var bootstrapSent = false
    private var contextSent = false
    private var expectsProductRequest = false
    private var requestedProductRefs: [String]?
    private var bootstrapped = false
    private var rendered = false
    private var expectsRenderReady = false
    private var resourceTask: Task<Void, Never>?
    private var resourceLease: WebPaywallResourceLease?
    private var loadedPageURL: URL?
    private var productsTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var pendingMessages: [[String: Any]] = []

    /// 以会话和入口串联生命周期，不输出 custom、价格或桥接原文。
    func trace(_ event: String, _ detail: String = "") {
        WebPaywallDiagnostics.log(environmentConfiguration.runtimeEnvironment.rawValue, event,
            "session=\(sessionID) placement=\(environmentConfiguration.placement) document=\(document.documentId) elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)) \(detail)")
    }

    var presentationDeadline: Date?
    var allowsActions = true
    var requiresRenderReady = false

    var isReady: Bool { active && rendered }
    var isReusable: Bool { active && webView != nil }

    init(document: WebPaywallDocument, storefrontGroup: String,
         environmentConfiguration: WebPaywallEnvironmentConfiguration,
         custom: [String: WebPaywallJSONValue]) {
        self.document = document
        self.storefrontGroup = storefrontGroup
        self.environmentConfiguration = environmentConfiguration
        self.custom = custom
    }

    /// 每次展示重新绑定宿主与状态回调，页面和握手本身保持在 WebView 中。
    func attach(host: PaywallHost, onReady: @escaping () -> Void,
                onFailure: @escaping () -> Void,
                onContentHeightChange: ((CGFloat) -> Void)? = nil,
                onTypedFailure: ((PaywallFailure) -> Void)? = nil,
                onResourceSource: ((String) -> Void)? = nil) {
        self.onContentHeightChange = onContentHeightChange
        self.host = host
        self.onReady = onReady
        self.onFailure = onFailure
        self.onTypedFailure = onTypedFailure
        self.onResourceSource = onResourceSource
        trace("session.attach", "ready=\(rendered) actions=\(allowsActions)")
        attached = true
        attachmentRevision += 1
        // 完成于弹窗外的加载，应在下一轮主线程通知新 SwiftUI 视图。
        if rendered {
            DispatchQueue.main.async { [weak self] in
                if let self { self.onResourceSource?(self.resourceSource) }
                self?.onReady?()
                if let height = self?.contentHeight { self?.onContentHeightChange?(height) }
            }
        }
        DispatchQueue.main.async { [weak self] in self?.flushPendingMessages() }
        notifyPresentationWhenReady()
    }

    /// SwiftUI 状态变化时更新业务出口，避免隐藏准备阶段的回调捕获旧状态。
    func updateHost(_ host: PaywallHost) {
        self.host = host
    }

    /// 弹窗关闭后重置滚动并解除旧宿主引用，异步交易结果留待下次展示投递。
    func detach() {
        trace("session.detach")
        if rendered, allowsActions {
            send(["type": "presentationState", "sessionID": sessionID, "visible": false])
        }
        // 预加载完成也会解除绑定，只有正式展示后的关闭才重置滚动。
        if attached, allowsActions { resetScrollPosition() }
        attached = false
        attachmentRevision += 1
        host = nil
        onContentHeightChange = nil
        onReady = nil
        onFailure = nil
        onTypedFailure = nil
        onResourceSource = nil
    }

    /// 关闭时立即回到顶部，保留横向位置、页面状态与已加载资源。
    private func resetScrollPosition() {
        guard let webView else { return }
        // 原生滚动和 H5 内部 overflow 容器分别归零，不触发平滑滚动。
        let scrollView = webView.scrollView
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: -scrollView.adjustedContentInset.top),
            animated: false)
        let script = """
        (() => {
            const elements = [document.scrollingElement, ...document.querySelectorAll('*')];
            for (const element of new Set(elements)) {
                if (element && element.scrollTop !== 0) {
                    element.scrollTo({ top: 0, left: element.scrollLeft, behavior: 'instant' });
                }
            }
        })();
        """
        // 直接投递到当前文档；不加入桥消息队列，避免下次展示时重复重置。
        webView.evaluateJavaScript(script) { [weak self] _, error in
            if error != nil { self?.trace("scroll.reset_failed") }
        }
    }

    /// WebView 重新加入页面后再补发收起期间产生的交易结果。
    private func flushPendingMessages() {
        guard active, attached else { return }
        let queued = pendingMessages
        pendingMessages.removeAll()
        queued.forEach(send)
    }

    /// 先准备环境和页面，用同一个截止时间覆盖握手、商品和首屏准备。
    func start(webView: WKWebView, preloading: Bool = false) {
        guard self.webView == nil, active else { return }
        trace("session.start", "preloading=\(preloading)")
        self.webView = webView
        guard host?.bridge != nil else { fail(); return }
        // 两项任务均可取消；查询完成后仍须检查会话是否存活。
        productsTask = Task { [weak self] in
            guard let self else { return }
            await self.prepareEnvironment()
        }
        if !preloading { beginPresentationDeadline() }
        loadPage(webView)
    }

    /// 普通展示与预加载统一准备静态包，异步完成后再次确认会话存活。
    private func loadPage(_ webView: WKWebView) {
        resourceTask = Task { [weak self, weak webView] in
            guard let self, let webView else { return }
            if let directory = document.localReadAccessURL {
                trace("page.load", "source=bundled")
                resourceSource = "bundled"
                onResourceSource?(resourceSource)
                loadedPageURL = document.pageURL
                webView.loadFileURL(document.pageURL, allowingReadAccessTo: directory)
                return
            }
            // 包缺失或校验失败只回到当前远端版本，不查找历史包。
            let lease = try? await WebPaywallResourceCache.shared.prepare(
                document: document, runtimeEnvironment: environmentConfiguration.runtimeEnvironment.rawValue)
            guard active, !Task.isCancelled else { return }
            trace("page.load", "source=\(lease == nil ? "remote" : "disk")")
            resourceLease = lease
            resourceSource = lease == nil ? "remote" : "disk"
            onResourceSource?(resourceSource)
            loadedPageURL = lease?.pageURL ?? document.pageURL
            if let lease {
                webView.loadFileURL(lease.pageURL, allowingReadAccessTo: lease.readAccessURL)
            } else {
                webView.load(URLRequest(url: document.pageURL, cachePolicy: .useProtocolCachePolicy))
            }
        }
    }

    /// 屏幕外的 WebView 可能暂停绘制，展示时再开启首屏超时。
    func beginPresentationDeadline() {
        guard active, !rendered, deadlineTask == nil else { return }
        trace("render.deadline", "seconds=12")
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, min(12, self?.presentationDeadline?.timeIntervalSinceNow ?? 12)) * 1_000_000_000)) }
            catch { return }
            self?.fail("render_timeout", kind: self?.queryingProducts == true ? .productsUnavailable : .renderTimeout)
        }
    }

    /// 关闭会话只取消本地等待，不替宿主决定已发起的交易结果。
    func stop() {
        trace("session.stop", "active=\(active)")
        active = false
        attached = false
        pendingMessages.removeAll()
        resourceTask?.cancel()
        resourceLease = nil
        productsTask?.cancel()
        deadlineTask?.cancel()
        actionTask?.cancel()
        webView?.stopLoading()
    }

    /// 故障只回退一次，拒绝之后到达的商品结果和桥接事件。
    private func fail(_ reason: String = "invalid_state_or_protocol", kind: PaywallFailure = .bridge) {
        guard active else { return }
        trace("session.failed", "reason=\(reason)")
        stop()
        onTypedFailure?(kind)
        onFailure?()
    }

    /// 先发送会话环境，页面据此选择正确的商品绑定。
    private func prepareEnvironment() async {
        // 未覆盖国家时读取商店账户店面，避免从语言或设备地区猜测。
        let country: String
        if let configured = environmentConfiguration.country {
            country = configured
        } else {
            let storefront = await Storefront.current
            country = storefront?.countryCode ?? ""
        }
        guard active, !Task.isCancelled else { return }
        environment = WebPaywallEnvironment.capture(
            country: country, configuration: environmentConfiguration)
        sendContextIfPossible()
    }

    /// 新页面收到环境后声明商品，旧页面仍可在 ready 后查询清单。
    private func sendContextIfPossible() {
        guard active, bridgeReady, let environment, !contextSent else { return }
        contextSent = true
        if expectsProductRequest {
            send(["type": "sessionContext", "bridgeVersion": 2, "sessionID": sessionID,
                  "custom": environment.customPayload(custom)])
        } else {
            queryProducts(document.productRefs)
        }
    }

    /// 请求必须属于当前会话、环境和发布清单，重复请求不会重新查询。
    private func receiveProductRequest(_ event: [String: Any]) {
        guard active, contextSent, expectsProductRequest, requestedProductRefs == nil else { return }
        guard event["bridgeVersion"] as? Int == 2,
              event["sessionID"] as? String == sessionID,
              event["runtimeEnvironment"] as? String == environmentConfiguration.runtimeEnvironment.rawValue,
              let refs = event["productRefs"] as? [String], !refs.isEmpty,
              refs.count == Set(refs).count, Set(refs).isSubset(of: Set(document.productRefs)) else {
            fail("invalid_product_request"); return
        }
        queryProducts(refs)
    }

    /// 锁定本次查询，取消或销毁后不允许晚到商品激活页面。
    private func queryProducts(_ refs: [String]) {
        guard active, requestedProductRefs == nil, let bridge = host?.bridge else { return }
        requestedProductRefs = refs
        productsTask = Task { [weak self] in
            guard let self else { return }
            await self.loadProducts(using: bridge)
        }
    }

    /// 页面声明需求并通过清单校验后才调用宿主商店查询。
    private func loadProducts(using bridge: any PaywallPurchaseBridge) async {
        queryingProducts = true
        defer { queryingProducts = false }
        trace("products.start", "requested=\(requestedProductRefs?.count ?? 0)")
        do {
            let values = try await bridge.products(
                references: requestedProductRefs ?? [], storefrontGroup: storefrontGroup)
            guard active, !Task.isCancelled else { return }
            // 只接收已通过发布清单校验的请求商品，忽略宿主额外返回项。
            for product in values where requestedProductRefs?.contains(product.productRef) == true {
                products[product.productRef] = product
            }
            trace("products.loaded", "matched=\(products.count) requested=\(requestedProductRefs?.count ?? 0)")
            guard !products.isEmpty || !bridge.requiresStoreProducts else { fail("products_empty", kind: .productsUnavailable); return }
            bootstrapIfPossible()
        } catch {
            guard active, !Task.isCancelled else { return }
            trace("products.failed", "code=\((error as NSError).code)")
            fail("products_query", kind: .productsUnavailable)
        }
    }

    /// 桥和商品都准备好后只注入一次；重复 ready 不会重复查询或重置购买状态。
    private func bootstrapIfPossible() {
        guard active, bridgeReady, (!products.isEmpty || host?.bridge.requiresStoreProducts == false),
              let environment, !bootstrapSent else { return }
        bootstrapSent = true
        let visible = (requestedProductRefs ?? []).compactMap { products[$0] }.map { product in
            var value: [String: Any] = ["productRef": product.productRef,
                         "displayPrice": product.displayPrice, "disclosure": product.disclosure]
            if let period = product.periodText { value["periodText"] = period }
            if let daily = product.dailyPriceText { value["dailyPriceText"] = daily }
            if let introductory = product.introductoryPriceText {
                value["introductoryPriceText"] = introductory
            }
            if let eligible = product.isEligibleForFreeTrial { value["isEligibleForFreeTrial"] = eligible }
            return value
        }
        let customPayload = environment.customPayload(custom)
        guard JSONSerialization.isValidJSONObject(customPayload) else { fail(); return }
        send(["type": "bootstrap", "bridgeVersion": 2, "sessionID": sessionID,
              "products": visible,
              "custom": customPayload, "capabilities": ["presentationState"]])
    }

    /// 只接收可信主文档的小型桥消息。
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard active, message.frameInfo.isMainFrame,
              let url = message.frameInfo.request.url, isAllowedPage(url),
              let text = message.body as? String, text.utf8.count <= 2_048,
              let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        handle(type: type, event: event)
    }

    /// 新页通过能力声明启用渲染回执，旧页继续使用 bootstrapped。
    private func handle(type: String, event: [String: Any]) {
        if ["ready", "productsRequest", "bootstrapped", "renderReady", "renderFailed", "purchase", "restore", "close", "terms", "privacy", "contentHeight"].contains(type) {
            trace("bridge.received", "type=\(type)")
        }
        switch type {
        case "ready":
            guard !bridgeReady else { return }
            guard event["bridgeVersion"] as? Int == 2 else { fail(); return }
            bridgeReady = true
            expectsRenderReady = (event["capabilities"] as? [String])?.contains("renderReady") == true
            guard !requiresRenderReady || expectsRenderReady else { fail(); return }
            expectsProductRequest = (event["capabilities"] as? [String])?.contains("productRequest") == true
            sendContextIfPossible()
        case "productsRequest":
            receiveProductRequest(event)
        case "bootstrapped":
            guard acceptsReceipt(event) else { return }
            bootstrapped = true
            if !expectsRenderReady { finishRendering() }
        case "renderReady":
            guard expectsRenderReady, bootstrapped, acceptsReceipt(event) else { return }
            finishRendering()
        case "contentHeight":
            // 仅接受已注入会话的有限高度；系统 detent 负责当前最大可用高度。
            guard attached, event["sessionID"] as? String == sessionID, acceptsReceipt(event),
                  let height = event["height"] as? Double,
                  height.isFinite, height > 0, height <= 100_000 else { return }
            contentHeight = CGFloat(height)
            onContentHeightChange?(CGFloat(height))
        case "renderFailed":
            if acceptsReceipt(event) || (contextSent && event["sessionID"] as? String == sessionID) { fail() }
        case "purchase", "restore":
            beginAction(type: type, event: event)
        case "close": if allowsActions, let host, host.allowsDismiss { host.dismiss() }
        case "terms": if allowsActions { host?.openLegal(.terms) }
        case "privacy": if allowsActions { host?.openLegal(.privacy) }
        default: break
        }
    }

    /// 新协议回执必须属于当前会话；兼容未携带会话标识的旧页面。
    private func acceptsReceipt(_ event: [String: Any]) -> Bool {
        guard active, bootstrapSent else { return false }
        if let received = event["sessionID"] as? String { return received == sessionID }
        return !expectsRenderReady
    }

    /// 移除原生遮罩前确认当前会话仍有效，并取消总加载超时。
    private func finishRendering() {
        guard active, !rendered else { return }
        trace("render.ready")
        rendered = true
        deadlineTask?.cancel()
        onReady?()
        notifyPresentationWhenReady()
    }

    /// 内嵌宿主在视频退场后显式开放展示，隐藏时阻断全部桥接操作。
    func setPresentationActive(_ value: Bool) {
        guard allowsActions != value else { return }
        if !value, rendered, attached {
            send(["type": "presentationState", "sessionID": sessionID, "visible": false])
        }
        allowsActions = value
        attachmentRevision += 1
        if value { notifyPresentationWhenReady() }
    }

    /// 正式挂载且首屏就绪后通知 H5；隐藏预加载不能消耗入场动画。
    private func notifyPresentationWhenReady() {
        guard active, attached, rendered, allowsActions else { return }
        let revision = attachmentRevision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, self.attached, self.rendered,
                  self.allowsActions, self.attachmentRevision == revision else { return }
            self.send(["type": "presentationState", "sessionID": self.sessionID,
                       "presentationID": revision, "visible": true])
        }
    }

    /// 交易沿用宿主实现；关闭后的返回值不再投递给旧 WebView。
    private func beginAction(type: String, event: [String: Any]) {
        guard allowsActions, attached, rendered, actionTask == nil, let host,
              host.bridge.requiresStoreProducts else { return }
        let product = (event["productRef"] as? String).flatMap { products[$0] }
        guard type == "restore" || product != nil else { return }
        trace("action.start", "type=\(type)")
        actionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.actionTask = nil }
            do {
                let result: PaywallPurchaseResult
                if let product, type == "purchase" {
                    result = try await host.bridge.purchase(product: product)
                } else {
                    result = try await host.bridge.restore()
                }
                self.trace("action.result", "type=\(type) result=\(result.rawValue)")
                self.send(["type": type + "Result", "result": result.rawValue])
            } catch {
                self.trace("action.failed", "type=\(type) code=\((error as NSError).code)")
                self.send(["type": type + "Result", "result": "failed"])
            }
        }
    }

    /// 检查 JS 接收器确实执行，避免可选调用静默失败后永久等待。
    private func send(_ message: [String: Any]) {
        guard active, JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        trace("bridge.send", "type=\(message["type"] as? String ?? "unknown") queued=\(!attached)")
        guard attached else { pendingMessages.append(message); return }
        let revision = attachmentRevision
        let script = "typeof window.PaywallRuntime?.receive === 'function' && (window.PaywallRuntime.receive(\(json)), true)"
        webView?.evaluateJavaScript(script) { [weak self] result, error in
            guard let self, self.active else { return }
            if error != nil || (result as? Bool) != true {
                // 上一弹窗的 JS 完成回调不得让新弹窗进入故障页。
                if !self.attached || self.attachmentRevision != revision {
                    self.pendingMessages.append(message)
                    DispatchQueue.main.async { [weak self] in self?.flushPendingMessages() }
                } else {
                    self.fail("javascript_delivery")
                }
            }
        }
    }

    /// 内置页只接受精确主文档；远端沿用宿主指定的 HTTPS 来源。
    private func isAllowedPage(_ url: URL) -> Bool {
        guard let expected = loadedPageURL else { return false }
        if expected.isFileURL {
            return url.isFileURL && url.resolvingSymlinksInPath() == expected.resolvingSymlinksInPath()
        }
        return url == expected
    }

    /// 保持现有来源限制，结束的会话禁止继续导航。
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = active && (navigationAction.request.url.map(isAllowedPage) ?? false)
        trace("navigation.policy", "allowed=\(allowed)")
        decisionHandler(allowed ? .allow : .cancel)
    }

    /// 完成握手后不允许主文档偷偷更换并复用旧商品会话。
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        trace("navigation.start")
        if bridgeReady { fail("unexpected_navigation") }
    }

    /// 主文档加载失败立即回退。
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) { fail("navigation_code_\((error as NSError).code)", kind: .resource) }

    /// 已开始的导航失败立即回退。
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) { fail("navigation_code_\((error as NSError).code)", kind: .resource) }

    /// WebKit 进程终止时不能继续展示空白页面。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail("web_process_terminated", kind: .resource) }
}
