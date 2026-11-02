import Foundation

/// 独立验证可选消息解析，不依赖设备或商店。
@main struct InteractionCheck {
    static func main() {
        let base: [String: Any] = ["bridgeVersion": 2, "targetID": "purchase", "action": "purchase", "productRef": "annual"]
        precondition(PaywallInteraction(message: base, productRefs: ["annual"])?.action == .purchase)
        for mutation: [String: Any] in [
            ["bridgeVersion": 1], ["targetID": ""], ["targetID": 123],
            ["targetID": String(repeating: "a", count: 161)], ["action": "unknown"],
            ["productRef": "unbound"], ["productRef": NSNull()]
        ] {
            precondition(PaywallInteraction(message: base.merging(mutation) { _, new in new }, productRefs: ["annual"]) == nil)
        }
        for action in ["purchase", "restore", "close", "terms", "privacy", "select", "toggle", "dismissDetails"] {
            precondition(PaywallInteraction(message: base.merging(["action": action]) { _, new in new }, productRefs: ["annual"]) != nil)
        }
        precondition(PaywallInteraction(message: ["bridgeVersion": 2, "targetID": "plan", "action": "select"], productRefs: ["annual"]) == nil)
        print("PASS interaction payload parsing and invalid-message rejection")
    }
}
