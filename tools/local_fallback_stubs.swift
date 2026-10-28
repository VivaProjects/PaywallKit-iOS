import Foundation

// macOS 集成驱动只替换 SwiftUI 客户端外壳；本地选择、交接和校验执行生产代码。
struct PaywallPlacement {
    enum Presentation { case fullScreen }
    let name: String
    let document: WebPaywallDocument
    let presentation: Presentation
    let sessionPolicy: Int?
    let clientID: UUID
    var fallbackContext: PaywallFallbackContext?
    var resourceLease: WebPaywallResourceLease?
}

@MainActor
final class PaywallClient {
    let id = UUID()
    func isPlacementDisabled(_ placement: String) -> Bool { false }
    func previousPlacement(_ placement: PaywallPlacement) async throws -> (PaywallPlacement, WebPaywallResourceLease)? { nil }
    func launchFallback(_ placement: String) async throws -> PaywallPlacement? { nil }
}
