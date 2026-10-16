import WebKit

/// 统一在线、离线和预加载页面的交互限制，禁止长按选择与系统菜单。
enum WebPaywallWebViewFactory {
    /// 在首次加载前关闭文本交互，并为每个文档和子框架安装菜单限制。
    static func make(configuration: WKWebViewConfiguration) -> WebPaywallDiagnosticWebView {
        // 使用公开偏好关闭 WebKit 文本选择，不移除滚动或点击手势。
        configuration.preferences.isTextInteractionEnabled = false
        configuration.userContentController.addUserScript(WKUserScript(
            source: interactionScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .defaultClient
        ))
        // 链接预览包含系统复制菜单，需要与文字选择一同关闭。
        let webView = WebPaywallDiagnosticWebView(frame: .zero, configuration: configuration)
        webView.allowsLinkPreview = false
        return webView
    }

    private static let interactionScript = """
    (() => {
      const style = document.createElement('style');
      style.textContent = `
        * {
          -webkit-user-select: none !important;
          user-select: none !important;
          -webkit-touch-callout: none !important;
        }
      `;
      document.documentElement.appendChild(style);
      // 只拦截选择、复制和菜单事件，保留页面按钮及滚动行为。
      for (const name of ['selectstart', 'copy', 'cut', 'contextmenu']) {
        document.addEventListener(name, event => event.preventDefault(), true);
      }
    })();
    """
}
