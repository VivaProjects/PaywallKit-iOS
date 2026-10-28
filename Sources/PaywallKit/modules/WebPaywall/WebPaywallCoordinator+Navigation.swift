import WebKit

/// 导航事件与来源门禁集中维护，日志不改变原有导航决定。
extension WebPaywallCoordinator: WKNavigationDelegate {
    /// 保持现有来源限制，结束的会话禁止继续导航。
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = active && (navigationAction.request.url.map { WebPaywallPageScripts.allows($0, expected: loadedPageURL) } ?? false)
        trace("navigation.policy", "allowed=\(allowed)")
        decisionHandler(allowed ? .allow : .cancel)
    }

    /// 主文档导航结束不代表价格和首屏就绪，单独记录以区分 H5 等待。
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        trace("navigation.finished")
    }

    /// 完成握手后不允许更换主文档并复用旧商品会话。
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
