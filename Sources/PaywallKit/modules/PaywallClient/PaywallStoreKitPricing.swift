import Foundation
import StoreKit

/// 两端 SDK 各自保存独立实现，不依赖相邻仓库。
@available(iOS 15.0, *)
enum PaywallStoreKitPricing {
    /// 仅映射已确认适用的优惠；未知周期或优惠类型不生成可能误导的阶段数据。
    static func phases(_ product: Product, eligibleOffer: Product.SubscriptionOffer?) throws -> PaywallSubscriptionPricing? {
        guard let period = product.subscription?.subscriptionPeriod,
              let regularPeriod = isoPeriod(period) else { return nil }
        let currency = product.priceFormatStyle.currencyCode
        var phases: [PaywallPricingPhase] = []
        if let offer = eligibleOffer {
            guard let offerPeriod = isoPeriod(offer.period), offer.periodCount > 0 else { return nil }
            let count: Int
            switch offer.paymentMode {
            case .freeTrial, .payUpFront: count = 1
            case .payAsYouGo: count = offer.periodCount
            default: return nil
            }
            phases.append(try phase(amount: offer.price, displayPrice: offer.displayPrice,
                currency: currency, period: offerPeriod, count: count, mode: "finiteRecurring"))
        }
        phases.append(try phase(amount: product.price, displayPrice: product.displayPrice,
            currency: currency, period: regularPeriod, count: 0, mode: "infiniteRecurring"))
        return try PaywallSubscriptionPricing(phases: phases)
    }

    /// StoreKit 的价格是每周期金额；预付费优惠周期本身就是完整付费时长。
    private static func phase(amount: Decimal, displayPrice: String, currency: String,
                              period: String, count: Int, mode: String) throws -> PaywallPricingPhase {
        guard let recurrence = PaywallPricingPhase.RecurrenceMode(rawValue: mode) else {
            throw PaywallPricingPhase.ValidationError.invalidPricing
        }
        return try PaywallPricingPhase(priceAmount: NSDecimalNumber(decimal: amount).stringValue,
            currencyCode: currency, displayPrice: displayPrice, billingPeriod: period,
            billingCycleCount: count, recurrenceMode: recurrence)
    }

    /// 将商店周期规范化为两端均可表达的 ISO 8601 单位，不按天数猜测月份。
    private static func isoPeriod(_ period: Product.SubscriptionPeriod) -> String? {
        guard period.value > 0 else { return nil }
        let unit: String
        switch period.unit {
        case .day: unit = "D"
        case .week: unit = "W"
        case .month: unit = "M"
        case .year: unit = "Y"
        @unknown default: return nil
        }
        return "P\(period.value)\(unit)"
    }
}
