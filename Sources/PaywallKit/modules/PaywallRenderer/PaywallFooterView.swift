import SwiftUI

/// 极大字体或长披露文案时，底栏可独立滚动且仍为正文保留空间。
@MainActor struct PaywallFooterView: View {
    let availableHeight: CGFloat
    @ObservedObject var model: PaywallRuntimeModel
    @State private var contentHeight: CGFloat = 1

    var body: some View {
        ScrollView {
            PaywallPurchaseBarView(model: model)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: FooterHeightKey.self, value: proxy.size.height)
                })
        }
        .frame(height: min(contentHeight, max(44, availableHeight * 0.45)))
        .onPreferenceChange(FooterHeightKey.self) { contentHeight = $0 }
        .background(Color(uiColor: .systemBackground))
    }
}

private struct FooterHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
