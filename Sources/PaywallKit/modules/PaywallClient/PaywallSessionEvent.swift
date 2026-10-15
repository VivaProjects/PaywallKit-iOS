import Foundation

/// 明确区分主动关闭、交易结果与页面失败，业务无需通过关闭回调猜测来源。
public enum PaywallSessionEvent {
    case ready(productRefs: [String])
    case resolved(PaywallSessionResolution)
    case closed
    case retrying
    case purchaseFinished(productRef: String, result: PaywallPurchaseResult)
    case restoreFinished(PaywallPurchaseResult)
    case actionFailed(String)
    case failed(String)
}
