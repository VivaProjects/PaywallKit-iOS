import SwiftUI

struct PaywallInformationView: View {
    let node: PaywallNode
    let snapshot: PaywallSnapshot
    @State private var expanded = false

    var body: some View {
        if node.props.collapsible == true {
            DisclosureGroup(isExpanded: $expanded) {
                Text(verbatim: snapshot.text(node.props.bodyKey))
            } label: {
                Text(verbatim: snapshot.text(node.props.titleKey))
            }
        } else {
            VStack(alignment: .leading) {
                Text(verbatim: snapshot.text(node.props.titleKey)).font(.headline)
                Text(verbatim: snapshot.text(node.props.bodyKey))
            }
        }
    }
}
