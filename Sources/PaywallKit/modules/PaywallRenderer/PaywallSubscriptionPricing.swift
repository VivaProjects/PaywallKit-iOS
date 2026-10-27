import Foundation

/// 商店选定购买方案的收费阶段，不包含优惠历史、营销文案或平台购买令牌。
public struct PaywallSubscriptionPricing {
    public let phases: [PaywallPricingPhase]

    /// 只接受完整且同币种的方案，禁止无限续订阶段后再追加优惠。
    public init(phases: [PaywallPricingPhase]) throws {
        guard !phases.isEmpty,
              Set(phases.map(\.currencyCode)).count == 1,
              !phases.dropLast().contains(where: { $0.recurrenceMode != .finiteRecurring }) else {
            throw PaywallPricingPhase.ValidationError.invalidPricing
        }
        self.phases = phases
    }

    var payload: [String: Any] { ["phases": phases.map(\.payload)] }
}

/// 两端共有的价格、币种、ISO 8601 周期和收费次数。
public struct PaywallPricingPhase {
    public enum RecurrenceMode: String { case finiteRecurring, infiniteRecurring, nonRecurring }
    public enum ValidationError: Error { case invalidPricing }
    public let priceAmount: String
    public let currencyCode: String
    public let displayPrice: String
    public let billingPeriod: String
    public let billingCycleCount: Int
    public let recurrenceMode: RecurrenceMode

    /// 金额使用十进制字符串避免浮点误差；周期来自商店，不能由页面猜测。
    public init(priceAmount: String, currencyCode: String, displayPrice: String,
                billingPeriod: String, billingCycleCount: Int, recurrenceMode: RecurrenceMode) throws {
        guard priceAmount.range(of: #"^(0|[1-9][0-9]*)(\.[0-9]+)?$"#, options: .regularExpression) != nil,
              currencyCode.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil,
              !displayPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              billingPeriod.range(of: #"^P[1-9][0-9]*[DWMY]$"#, options: .regularExpression) != nil,
              recurrenceMode == .finiteRecurring ? billingCycleCount > 0 : billingCycleCount == 0 else {
            throw ValidationError.invalidPricing
        }
        self.priceAmount = priceAmount
        self.currencyCode = currencyCode
        self.displayPrice = displayPrice
        self.billingPeriod = billingPeriod
        self.billingCycleCount = billingCycleCount
        self.recurrenceMode = recurrenceMode
    }

    var payload: [String: Any] {
        ["priceAmount": priceAmount, "currencyCode": currencyCode, "displayPrice": displayPrice,
         "billingPeriod": billingPeriod, "billingCycleCount": billingCycleCount,
         "recurrenceMode": recurrenceMode.rawValue]
    }
}
