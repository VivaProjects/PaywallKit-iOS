import Foundation

/// H5 的展示交互通知；宿主可选择触觉反馈，不代表购买或选中结果。
public struct PaywallInteraction: Equatable, Sendable {
    public enum Action: String, Sendable {
        case purchase, restore, close, terms, privacy, select, toggle, dismissDetails
    }
    public let targetID: String
    public let action: Action
    public let productRef: String?

    /// 严格解析可选桥消息；不接受未知动作或任意页面数据。
    init?(message: [String: Any], productRefs: [String]) {
        guard message["bridgeVersion"] as? Int == 2,
              let target = message["targetID"] as? String,
              !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              target.count <= 160,
              let rawAction = message["action"] as? String,
              let action = Action(rawValue: rawAction) else { return nil }
        let ref = message["productRef"] as? String
        if message["productRef"] != nil && (ref == nil || !productRefs.contains(ref!)) { return nil }
        if action == .select && ref == nil { return nil }
        self.targetID = target
        self.action = action
        self.productRef = ref
    }
}
