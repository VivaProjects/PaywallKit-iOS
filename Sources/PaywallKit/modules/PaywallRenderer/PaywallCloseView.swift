import SwiftUI

@MainActor struct PaywallCloseView: View {
    let label: String
    @ObservedObject var model: PaywallRuntimeModel

    var body: some View {
        if model.host.allowsDismiss {
            Button { model.dismiss() } label: {
                Image(systemName: "xmark").frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text(verbatim: label))
            .disabled(model.isPurchasing)
        }
    }
}
