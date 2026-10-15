import Foundation

/// 宿主固定商品引用映射，JSON 无权增加商店商品。
public struct PaywallCatalog {
    public let productRefs: [String]
    public let recommendedRef: String

    public init(productRefs: [String], recommendedRef: String) {
        self.productRefs = productRefs
        self.recommendedRef = recommendedRef
    }
}
