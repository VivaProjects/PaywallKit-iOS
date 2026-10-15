import Foundation

/// 生命周期内不可变：语言、商品引用、入口、版本和 storefront 一起冻结。
public struct PaywallSnapshot {
    let document: PaywallDocument
    let language: PaywallDocument.Language
    public internal(set) var assignment: [String: String] = [:]
    public let locale: String
    public let storefrontGroup: String
    public let productRefs: [String]
    public let recommendedRef: String
    public var documentId: String { document.documentId }
    public var revision: Int { document.revision }
    public var placement: String { document.placement }

    /// 读取验证过的语言键；渲染层不再消费原始字典。
    func text(_ key: String?) -> String { language.strings[key ?? ""] ?? "" }

    /// 使用同一套 BCP-47 截断顺序进行语言回退。
    static func localeChain(_ locale: String, fallback: String) -> [String] {
        var parts = locale.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        var chain: [String] = []
        while !parts.isEmpty {
            chain.append(parts.joined(separator: "-"))
            parts.removeLast()
        }
        if !chain.contains(fallback) { chain.append(fallback) }
        return chain
    }
}
