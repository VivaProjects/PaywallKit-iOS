import SwiftUI

/// 在真实宿主尺寸中渲染待用页面；无触摸、无辅助功能、无业务曝光。
@MainActor
public struct PaywallPreloadView: View {
    @ObservedObject private var preload: PaywallPreload

    public init(preload: PaywallPreload) {
        self.preload = preload
    }

    public var body: some View {
        Group {
            if preload.isPreparing, let page = preload.page {
                PaywallPreparationView(page: page,
                                       onReady: { [weak preload] in preload?.ready(page) },
                                       onFailure: { [weak preload] in preload?.failed(page) })
                    .id(ObjectIdentifier(page))
            }
        }
        .ignoresSafeArea(.container, edges: .all)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
