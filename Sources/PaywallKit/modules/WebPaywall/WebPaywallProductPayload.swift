import Foundation

/// 商品更新只携带真实商店报价，首次空商品初始化不伪造价格。
enum WebPaywallProductPayload {
    /// 按 H5 已通过校验的请求顺序生成桥接数据。
    static func make(references: [String], products: [String: PaywallStoreProduct]) -> [[String: Any]] {
        references.compactMap { products[$0] }.map { product in
            var value: [String: Any] = ["productRef": product.productRef,
                "displayPrice": product.displayPrice, "disclosure": product.disclosure]
            if let period = product.periodText { value["periodText"] = period }
            if let daily = product.dailyPriceText { value["dailyPriceText"] = daily }
            if let introductory = product.introductoryPriceText { value["introductoryPriceText"] = introductory }
            if let eligible = product.isEligibleForFreeTrial { value["isEligibleForFreeTrial"] = eligible }
            if let pricing = product.subscriptionPricing { value["subscriptionPricing"] = pricing.payload }
            return value
        }
    }

    /// 首屏提前展示后仍为商品等待设置上限；旧页面保留原有查询行为。
    @MainActor
    static func load(bridge: any PaywallPurchaseBridge, references: [String],
                     group: String, deferred: Bool) async throws -> [PaywallStoreProduct] {
        guard deferred else { return try await bridge.products(references: references, storefrontGroup: group) }
        return try await PaywallDeadline<[PaywallStoreProduct]>().run(until: Date().addingTimeInterval(12)) {
            try await bridge.products(references: references, storefrontGroup: group)
        }
    }
}
