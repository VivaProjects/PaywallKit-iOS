import Foundation

public struct PaywallEvent: Sendable {
    public enum Name: String, Sendable {
        case configFallback = "paywall_config_fallback"
        case impression = "paywall_impression"
        case selected = "paywall_product_selected"
        case purchaseStarted = "paywall_purchase_started"
        case purchaseResult = "paywall_purchase_result"
        case restoreResult = "paywall_restore_result"
        case renderError = "paywall_render_error"
        case dismissed = "paywall_dismissed"
    }
    public let name: Name
    public let documentId: String
    public let revision: Int
    public let placement: String
    public let variant: String
    public let rendererVersion: Int
    public let fields: [String: String]
}
