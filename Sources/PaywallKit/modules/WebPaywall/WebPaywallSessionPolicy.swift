import Foundation

/// 服务端给点位绑定的交易权限与接续规则，不由 H5 或本地商品角色推断。
public struct WebPaywallSessionPolicy {
    public let purchasableProductRefs: [String]
    public let optionalProductRefs: [String]
    public let custom: [String: WebPaywallJSONValue]
    public let nextPlacement: String?

    /// 每项引用必须属于该点位完整商品列表；对比商品可缺失但不可购买。
    private init(raw: [String: Any], document: WebPaywallDocument, placements: [String: String],
                 placement: String) throws {
        guard Set(raw.keys).isSubset(of: ["purchasableProductRefs", "optionalProductRefs", "custom", "nextPlacement"]),
              let purchases = raw["purchasableProductRefs"] as? [String], !purchases.isEmpty,
              purchases.count == Set(purchases).count,
              purchases.contains(document.initialProductRef),
              purchases.allSatisfy({ document.productRefs.contains($0) }),
              let optional = raw["optionalProductRefs"] as? [String],
              optional.count == Set(optional).count,
              optional.allSatisfy({ document.productRefs.contains($0) && !purchases.contains($0) }),
              let custom = raw["custom"] as? [String: String], custom.count <= 16,
              custom.allSatisfy({ !$0.key.isEmpty && $0.key.count <= 64 && $0.value.count <= 256 })
        else { throw WebPaywallError.invalidDocument }
        let reserved = Set(["products", "price", "displayPrice", "disclosure", "content", "language",
                            "country", "deviceModel", "appVersion"])
        guard reserved.isDisjoint(with: custom.keys) else { throw WebPaywallError.invalidDocument }
        if let next = raw["nextPlacement"] {
            guard let name = next as? String, name != placement, placements[name] != nil else {
                throw WebPaywallError.invalidDocument
            }
        }
        purchasableProductRefs = purchases
        optionalProductRefs = optional
        self.custom = custom.mapValues { .string($0) }
        nextPlacement = raw["nextPlacement"] as? String
    }

    /// 整份配置先验证规则与点位引用，缺失规则不会在 SDK 中推测业务角色。
    static func parse(_ value: Any?, placements: [String: String],
                      documents: [String: WebPaywallDocument]) throws -> [String: Self] {
        guard let value else { return [:] }
        guard let entries = value as? [String: [String: Any]],
              entries.keys.allSatisfy({ placements[$0] != nil }) else { throw WebPaywallError.invalidDocument }
        var policies: [String: Self] = [:]
        for (placement, raw) in entries {
            guard let id = placements[placement], let document = documents[id] else {
                throw WebPaywallError.invalidDocument
            }
            policies[placement] = try Self(raw: raw, document: document, placements: placements, placement: placement)
        }
        return policies
    }
}
