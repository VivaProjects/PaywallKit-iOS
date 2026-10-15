import Foundation

/// 宿主只提供本次会话的业务约束与交易适配，不负责 Host 或 WebView 的构造。
@MainActor
public struct PaywallSessionInput {
    public let document: WebPaywallDocument
    public let purchaseBridge: any PaywallPurchaseBridge
    public let custom: [String: WebPaywallJSONValue]
    public let environment: WebPaywallEnvironmentConfiguration

    public init(document: WebPaywallDocument, purchaseBridge: any PaywallPurchaseBridge,
                custom: [String: WebPaywallJSONValue] = [:],
                environment: WebPaywallEnvironmentConfiguration = .init()) {
        self.document = document
        self.purchaseBridge = purchaseBridge
        self.custom = custom
        self.environment = environment
    }

    /// 解析点位后冻结真实入口名称，避免共享页面误报 documentId。
    func forPlacement(_ placement: String) -> Self {
        Self(document: document, purchaseBridge: purchaseBridge, custom: custom,
             environment: environment.forPlacement(placement))
    }
}
