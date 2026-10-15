import SwiftUI

/// 资源和路由由宿主预注册；文档仅提供受限标识。
@MainActor public struct PaywallHost {
    public enum LegalRoute: String { case privacy, terms }
    public let bridge: any PaywallPurchaseBridge
    public let allowsDismiss: Bool
    public let image: (String) -> Image?
    public let openLegal: (LegalRoute) -> Void
    public let dismiss: () -> Void
    public let track: (PaywallEvent) -> Void
    public let copy: PaywallRuntimeCopy

    public init(bridge: any PaywallPurchaseBridge, allowsDismiss: Bool,
                image: @escaping (String) -> Image?, openLegal: @escaping (LegalRoute) -> Void,
                dismiss: @escaping () -> Void, track: @escaping (PaywallEvent) -> Void,
                copy: PaywallRuntimeCopy = .init()) {
        self.bridge = bridge
        self.allowsDismiss = allowsDismiss
        self.image = image
        self.openLegal = openLegal
        self.dismiss = dismiss
        self.track = track
        self.copy = copy
    }
}
