import Foundation

/// 宿主实现 StoreKit 查询、购买与恢复，配置层不接触金额或 offerToken。
@MainActor public protocol PaywallPurchaseBridge: AnyObject {
    var requiresStoreProducts: Bool { get }
    var allowsStoreActions: Bool { get }
    func products(references: [String], storefrontGroup: String) async throws -> [PaywallStoreProduct]
    func purchase(product: PaywallStoreProduct) async throws -> PaywallPurchaseResult
    func restore() async throws -> PaywallPurchaseResult
}

public enum PaywallPurchaseResult: String {
    case succeeded, cancelled, pending, noEntitlement
}

public extension PaywallPurchaseBridge {
    /// 默认保持付费页面必须取得商店商品；纯展示宿主可显式关闭商品依赖。
    var requiresStoreProducts: Bool { true }

    /// 默认兼容旧纯展示桥；允许空商品展示的交易宿主可独立开启交易。
    var allowsStoreActions: Bool { requiresStoreProducts }
}
