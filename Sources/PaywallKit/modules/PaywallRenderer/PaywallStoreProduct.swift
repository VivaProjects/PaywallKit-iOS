import Foundation

/// 所有可见价格与订阅披露必须由宿主商店适配层生成。
public struct PaywallStoreProduct: Identifiable {
    public let productRef: String
    public let storeProductID: String
    public let title: String
    public let displayPrice: String
    public let periodText: String?
    public let disclosure: String
    public let dailyPriceText: String?
    public let introductoryPriceText: String?
    public let isEligibleForFreeTrial: Bool?
    public let subscriptionPricing: PaywallSubscriptionPricing?
    public var id: String { productRef }

    public init(productRef: String, storeProductID: String, title: String, displayPrice: String,
                disclosure: String, periodText: String? = nil, dailyPriceText: String? = nil,
                introductoryPriceText: String? = nil, isEligibleForFreeTrial: Bool? = nil,
                subscriptionPricing: PaywallSubscriptionPricing? = nil) {
        self.subscriptionPricing = subscriptionPricing
        self.productRef = productRef
        self.storeProductID = storeProductID
        self.title = title
        self.displayPrice = displayPrice
        self.periodText = periodText
        self.disclosure = disclosure
        self.dailyPriceText = dailyPriceText
        self.introductoryPriceText = introductoryPriceText
        self.isEligibleForFreeTrial = isEligibleForFreeTrial
    }
}
