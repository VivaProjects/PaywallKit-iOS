import SwiftUI
import UIKit

/// 仅承载待展示网页的布局与渲染，不挂载业务 View，也不发送曝光或交易事件。
@MainActor
struct PaywallPreparationView: UIViewRepresentable {
    let page: PaywallPreparedPage
    let onReady: () -> Void
    let onFailure: () -> Void

    /// 等待真实窗口与非零尺寸后启动，不用屏幕型号或固定尺寸模拟首屏。
    func makeUIView(context: Context) -> PreparationContainer {
        let container = PreparationContainer()
        container.isUserInteractionEnabled = false
        container.accessibilityElementsHidden = true
        container.start = { [weak container] in
            guard let container, !page.isCancelled else { return }
            let input = page.input
            let host = PaywallHost(bridge: input.purchaseBridge, allowsDismiss: false,
                                  image: { _ in nil }, openLegal: { _ in },
                                  dismiss: {}, track: { _ in })
            page.cache.preload(document: input.document, storefrontGroup: page.placement.name,
                               host: host, environment: input.environment, custom: input.custom,
                               onFailure: onFailure, onReady: onReady)
            page.cache.mountPreload(in: container)
        }
        return container
    }

    func updateUIView(_ uiView: PreparationContainer, context: Context) {}

    /// 正式弹窗会接管缓存，隐藏容器卸载只断开布局回调，不销毁已就绪页面。
    static func dismantleUIView(_ uiView: PreparationContainer, coordinator: ()) {
        uiView.start = nil
    }

    final class PreparationContainer: UIView {
        var start: (() -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            startIfVisibleInHierarchy()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            startIfVisibleInHierarchy()
        }

        /// 在下一轮主线程启动，避免在 SwiftUI 布局回调中同步修改展示状态。
        private func startIfVisibleInHierarchy() {
            guard window != nil, bounds.width > 0, bounds.height > 0,
                  let action = start else { return }
            start = nil
            DispatchQueue.main.async { [weak self] in
                guard self?.window != nil else { return }
                action()
            }
        }
    }
}
