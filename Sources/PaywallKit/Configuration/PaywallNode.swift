import Foundation

struct PaywallNode: Decodable, Identifiable {
    let type: Kind
    let nodeId: String
    let props: Props
    let children: [PaywallNode]?
    var id: String { nodeId }

    enum Kind: String, Decodable {
        case paywallScreen, hero, heading, benefitList, productPicker
        case informationSection, legalActions, spacer, purchaseBar, closeButton
    }
    struct Props: Decodable {
        let backgroundToken: String?
        let assetId: String?
        let altKey: String?
        let aspectRatio: Double?
        let textKey: String?
        let typography: String?
        let alignment: String?
        let itemsKey: String?
        let catalogKey: String?
        let selection: String?
        let titleKey: String?
        let bodyKey: String?
        let collapsible: Bool?
        let showRestore: Bool?
        let spacingToken: String?
        let labelKey: String?
        let action: Action?
    }
    struct Action: Decodable {
        let type: String
        let reason: String?
    }
}
