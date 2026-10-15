import SwiftUI

@MainActor struct PaywallHeroView: View {
    let node: PaywallNode
    let snapshot: PaywallSnapshot
    let host: PaywallHost

    var body: some View {
        Group {
            if let image = host.image(node.props.assetId ?? "") {
                image.resizable().scaledToFit()
            } else {
                // 非关键图片失败使用语义占位，不阻断商店操作。
                Image(systemName: "photo").resizable().scaledToFit().padding(32)
            }
        }
        .aspectRatio(node.props.aspectRatio ?? 1.8, contentMode: .fit)
        .accessibilityLabel(Text(verbatim: snapshot.text(node.props.altKey)))
    }
}
