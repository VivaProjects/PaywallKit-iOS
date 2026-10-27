import Foundation

/// 独立执行模型回归，不依赖应用、商店账号或 WebView。
@main
struct CheckSubscriptionPricing {
    static func main() throws {
        let intro = try PaywallPricingPhase(priceAmount: "7.99", currencyCode: "EUR",
            displayPrice: "7,99 €", billingPeriod: "P1M", billingCycleCount: 1, recurrenceMode: .finiteRecurring)
        let regular = try PaywallPricingPhase(priceAmount: "19.99", currencyCode: "EUR",
            displayPrice: "19,99 €", billingPeriod: "P1M", billingCycleCount: 0, recurrenceMode: .infiniteRecurring)
        let pricing = try PaywallSubscriptionPricing(phases: [intro, regular])
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "protocol/subscription-pricing.example.json"))) as! NSDictionary
        precondition(NSDictionary(dictionary: pricing.payload) == expected)
        let noOffer = try PaywallSubscriptionPricing(phases: [regular])
        precondition(noOffer.phases.count == 1)
        let trial = try PaywallPricingPhase(priceAmount: "0", currencyCode: "EUR", displayPrice: "0,00 €",
            billingPeriod: "P7D", billingCycleCount: 1, recurrenceMode: .finiteRecurring)
        let trialPricing = try PaywallSubscriptionPricing(phases: [trial, regular])
        precondition(trialPricing.phases.count == 2)
        let legacy = PaywallStoreProduct(productRef: "monthly", storeProductID: "monthly",
            title: "", displayPrice: "19,99 €", disclosure: "monthly")
        precondition(legacy.subscriptionPricing == nil)
        precondition((try? PaywallSubscriptionPricing(phases: [regular, intro])) == nil)
        precondition((try? PaywallSubscriptionPricing(phases: [])) == nil)
        precondition((try? PaywallPricingPhase(priceAmount: "-1", currencyCode: "EUR", displayPrice: "-1 €",
            billingPeriod: "P1M", billingCycleCount: 0, recurrenceMode: .infiniteRecurring)) == nil)
        print("PASS common pricing fixture, trial, regular price, legacy omission and invalid phase rejection")
    }
}
