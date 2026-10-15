import Foundation

/// 原始模型保持模块私有；只有工厂能构造供渲染使用的快照。
struct PaywallDocument: Decodable {
    let documentId: String
    let revision: Int
    let schemaVersion: String
    let minimumRendererVersion: [String: Int]
    let requiredCapabilities: [String]
    let placement: String
    let localization: Localization
    let tokens: Tokens
    let tree: PaywallNode
    let bottomBar: PaywallNode
    let tracking: Tracking

    struct Localization: Decodable {
        let defaultLocale: String
        let locales: [String: Language]
    }
    struct Language: Decodable {
        let strings: [String: String]
        let lists: [String: [String]]
    }
    struct Tokens: Decodable {
        let color: [String: String]
        let spacing: [String: Int]
        let shape: [String: String]
    }
    struct Tracking: Decodable {
        let surface: String
        let variant: String
    }
}
