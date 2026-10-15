import SwiftUI

@MainActor public struct PaywallRendererView: View {
    @StateObject private var model: PaywallRuntimeModel

    public init(snapshot: PaywallSnapshot, host: PaywallHost) {
        _model = StateObject(wrappedValue: PaywallRuntimeModel(snapshot: snapshot, host: host))
    }

    public var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: CGFloat(model.snapshot.document.tokens.spacing["section"] ?? 20)) {
                    ForEach(model.snapshot.document.tree.children ?? []) { node in
                        PaywallNodeView(node: node, model: model)
                    }
                }
                .padding(CGFloat(model.snapshot.document.tokens.spacing["pageX"] ?? 24))
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PaywallFooterView(availableHeight: geometry.size.height, model: model)
        }
        .background(Color(uiColor: .systemBackground))
        .tint(model.snapshot.document.tokens.color["accent"] == "interactiveGreen" ? .green : .blue)
        .interactiveDismissDisabled(!model.host.allowsDismiss || model.isPurchasing)
        .task { await model.load() }
        }
    }
}
