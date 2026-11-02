import Foundation

/// 初始商品目录；宿主可显式接受可信页面清单中新声明的商品。
public struct PaywallCatalog {
    public let productRefs: [String]
    public let recommendedRef: String
    public let allowsDocumentProducts: Bool

    /// 默认保持固定白名单；动态模式仍由宿主桥接查询商店并验证购买权限。
    public init(productRefs: [String], recommendedRef: String, allowsDocumentProducts: Bool = false) {
        self.productRefs = productRefs
        self.recommendedRef = recommendedRef
        self.allowsDocumentProducts = allowsDocumentProducts
    }

    /// 动态授权仅用于已完成来源和包身份校验的清单，不接受空白商品 ID。
    func accepts(_ reference: String) -> Bool {
        guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return allowsDocumentProducts || productRefs.contains(reference)
    }
}
