import Foundation
import StoreKit

/// StoreKit 商品的默认协议转换器，宿主可复用或提供自己的本地化披露。
public enum PaywallStoreKitProductMapper {
    /// 把商店本地化商品、周期和已确认优惠转换为桥协议商品信息。
    public static func makeProduct(_ product: Product, includesDailyPrice: Bool = false) async -> PaywallStoreProduct {
        let period = product.subscription?.subscriptionPeriod
        let periodText = period.map(Self.periodText)
        let renewal = periodText.map { "\(product.displayPrice) / \($0)" } ?? product.displayPrice
        let eligibleOffer: Product.SubscriptionOffer?
        if let subscription = product.subscription,
           let offer = subscription.introductoryOffer,
           await subscription.isEligibleForIntroOffer {
            eligibleOffer = offer
        } else {
            eligibleOffer = nil
        }
        let disclosure = eligibleOffer.map { offer -> String in
            let intro = Self.introductoryText(offer)
            return "\(intro), then renews at \(renewal). Cancel anytime in your Apple account."
        } ?? "Automatically renews at \(renewal). Cancel anytime in your Apple account."
        return PaywallStoreProduct(
            productRef: product.id, storeProductID: product.id,
            title: product.displayName, displayPrice: product.displayPrice,
            disclosure: disclosure, periodText: periodText,
            dailyPriceText: includesDailyPrice ? dailyPrice(for: product) : nil,
            introductoryPriceText: eligibleOffer?.displayPrice,
            isEligibleForFreeTrial: eligibleOffer?.paymentMode == .freeTrial
        )
    }

    /// 只为年度订阅折算本地化日均金额，不解析展示字符串或使用云控美元价格。
    private static func dailyPrice(for product: Product) -> String? {
        guard let period = product.subscription?.subscriptionPeriod,
              period.unit == .year, period.value > 0 else { return nil }
        let daily = product.price / Decimal(365 * period.value)
        return daily.formatted(product.priceFormatStyle)
    }

    /// 以 StoreKit 周期构造商品说明，不从页面静态文案推断订阅周期。
    private static func periodText(_ period: Product.SubscriptionPeriod) -> String {
        let unit: String
        switch period.unit {
        case .day: unit = period.value == 1 ? "day" : "days"
        case .week: unit = period.value == 1 ? "week" : "weeks"
        case .month: unit = period.value == 1 ? "month" : "months"
        case .year: unit = period.value == 1 ? "year" : "years"
        @unknown default: unit = "period"
        }
        return "\(period.value) \(unit)"
    }

    /// 仅在商店确认当前账户有资格时描述试用或首期优惠。
    private static func introductoryText(_ offer: Product.SubscriptionOffer) -> String {
        let duration = periodText(offer.period)
        if offer.paymentMode == .freeTrial { return "Free for \(duration)" }
        if offer.paymentMode == .payAsYouGo {
            return "\(offer.displayPrice) per \(duration) for \(offer.periodCount) periods"
        }
        if offer.paymentMode == .payUpFront { return "\(offer.displayPrice) for \(duration)" }
        return "Introductory offer \(offer.displayPrice)"
    }

}
