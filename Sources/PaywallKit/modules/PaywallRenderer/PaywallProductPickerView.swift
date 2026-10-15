import SwiftUI

@MainActor struct PaywallProductPickerView: View {
    let nodeID: String
    @ObservedObject var model: PaywallRuntimeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isLoading { ProgressView(model.host.copy.loading) }
            if model.loadFailed {
                Text(verbatim: model.host.copy.unavailable)
                Button(model.host.copy.retry) { Task { await model.load() } }
            }
            ForEach(model.products) { product in
                Button { model.select(product, nodeID: nodeID) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Label {
                            Text(verbatim: product.title)
                        } icon: {
                            Image(systemName: model.selectedRef == product.productRef ? "checkmark.circle.fill" : "circle")
                        }
                        Text(verbatim: product.displayPrice).font(.headline)
                        Text(verbatim: product.disclosure).font(.caption)
                        if product.productRef == model.snapshot.recommendedRef {
                            Text(verbatim: model.host.copy.recommended).font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: radius))
                }
                .buttonStyle(.plain)
                .disabled(model.isPurchasing || model.isLoading)
                .accessibilityAddTraits(model.selectedRef == product.productRef ? [.isSelected] : [])
            }
        }
    }

    private var radius: CGFloat { model.snapshot.document.tokens.shape["card"] == "radius26" ? 26 : 16 }
}
