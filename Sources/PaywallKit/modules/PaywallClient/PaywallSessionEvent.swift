import Foundation

/// 明确区分主动关闭、交易结果与页面失败，业务无需通过关闭回调猜测来源。
public enum PaywallSessionEvent {
    /// 本次页面查询的商品 ID（包含商店未返回项），按请求顺序保留。
    /// 旧 H5 未声明 productRequest 能力时返回空数组，不以文档清单补齐。
    case ready(productRefs: [String])
    case resolved(PaywallSessionResolution)
    case closed
    case retrying
    case purchaseFinished(productRef: String, result: PaywallPurchaseResult)
    case restoreFinished(PaywallPurchaseResult)
    case actionFailed(String)
    case failed(String)
}
