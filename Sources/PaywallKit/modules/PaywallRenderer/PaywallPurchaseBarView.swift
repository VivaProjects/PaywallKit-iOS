import SwiftUI

@MainActor struct PaywallPurchaseBarView: View {
    @ObservedObject var model: PaywallRuntimeModel

    var body: some View {
        VStack(spacing: 8) {
            if let product = model.selectedProduct {
                Text(verbatim: product.displayPrice).font(.headline)
                Text(verbatim: product.disclosure).font(.caption)
            }
            if let message = model.message {
                Text(verbatim: message).font(.caption).accessibilityAddTraits(.updatesFrequently)
            }
            Button { model.purchase() } label: {
                HStack {
                    if model.isPurchasing { ProgressView() }
                    Text(verbatim: model.snapshot.text(model.snapshot.document.bottomBar.props.titleKey))
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(model.selectedProduct == nil || model.isPurchasing || model.isLoading)
        }
        .padding(16)
        .background(Color(uiColor: .systemBackground))
    }
}
