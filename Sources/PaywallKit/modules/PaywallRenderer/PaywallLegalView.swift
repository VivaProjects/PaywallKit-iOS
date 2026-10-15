import SwiftUI

@MainActor struct PaywallLegalView: View {
    @ObservedObject var model: PaywallRuntimeModel

    var body: some View {
        // 垂直布局容纳长语言和辅助字号；系统按钮提供完整语义。
        VStack(alignment: .leading, spacing: 4) {
            Button(model.host.copy.restore) { model.restore() }
                .disabled(model.isPurchasing)
            Button(model.host.copy.privacy) { model.host.openLegal(.privacy) }
            Button(model.host.copy.terms) { model.host.openLegal(.terms) }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}
