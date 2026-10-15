import SwiftUI

@MainActor struct PaywallNodeView: View {
    let node: PaywallNode
    // 静态节点不订阅价格状态，商品与 CTA 子视图单独观察。
    let model: PaywallRuntimeModel

    @ViewBuilder var body: some View {
        switch node.type {
        case .hero:
            PaywallHeroView(node: node, snapshot: model.snapshot, host: model.host)
        case .heading:
            Text(verbatim: model.snapshot.text(node.props.textKey))
                .font(node.props.typography == "titleXL" ? .largeTitle : node.props.typography == "caption" ? .caption : .body)
                .multilineTextAlignment(node.props.alignment == "center" ? .center : .leading)
                .frame(maxWidth: .infinity, alignment: node.props.alignment == "center" ? .center : .leading)
                .accessibilityAddTraits(.isHeader)
        case .benefitList:
            VStack(alignment: .leading, spacing: CGFloat(model.snapshot.document.tokens.spacing["itemGap"] ?? 12)) {
                ForEach(Array((model.snapshot.language.lists[node.props.itemsKey ?? ""] ?? []).enumerated()), id: \.offset) { _, text in
                    Label { Text(verbatim: text) } icon: { Image(systemName: "checkmark.circle") }
                }
            }
        case .productPicker:
            PaywallProductPickerView(nodeID: node.nodeId, model: model)
        case .informationSection:
            PaywallInformationView(node: node, snapshot: model.snapshot)
        case .legalActions:
            PaywallLegalView(model: model)
        case .spacer:
            Color.clear.frame(height: CGFloat(model.snapshot.document.tokens.spacing[node.props.spacingToken ?? ""] ?? 0))
                .accessibilityHidden(true)
        case .closeButton:
            PaywallCloseView(label: model.snapshot.text(node.props.labelKey), model: model)
        case .paywallScreen, .purchaseBar:
            EmptyView() // Schema 限定这两类节点只能出现在固定的根位置。
        }
    }
}
