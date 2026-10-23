import Foundation

/// 网页来源校验和退场滚动复位，不持有会话状态。
enum WebPaywallPageScripts {
    /// 恢复正文与内部滚动区域，避免复用时停留在上次位置。
    static let resetScroll = """
        (() => {
            const elements = [document.scrollingElement, ...document.querySelectorAll('*')];
            for (const element of new Set(elements)) {
                if (element && element.scrollTop !== 0) {
                    element.scrollTo({ top: 0, left: element.scrollLeft, behavior: 'instant' });
                }
            }
        })();
        """

    /// 仅允许当前加载的主文档发起桥接消息。
    static func allows(_ url: URL, expected: URL?) -> Bool {
        guard let expected else { return false }
        if expected.isFileURL {
            return url.isFileURL && url.resolvingSymlinksInPath() == expected.resolvingSymlinksInPath()
        }
        return url == expected
    }
}
