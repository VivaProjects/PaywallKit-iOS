import SwiftUI

/// 可见加载阶段的独立标识和取消能力；不包含价格、权益或缓存数据。
public struct PaywallLoadingState {
    public let id: UUID
    public let isLoading: Bool
    public let cancel: (@MainActor () -> Void)?
}

private struct PaywallLoadingHandlerKey: EnvironmentKey {
    static let defaultValue: (@MainActor (PaywallLoadingState) -> Void)? = nil
}

extension EnvironmentValues {
    var paywallLoadingHandler: (@MainActor (PaywallLoadingState) -> Void)? {
        get { self[PaywallLoadingHandlerKey.self] }
        set { self[PaywallLoadingHandlerKey.self] = newValue }
    }
}

extension View {
    /// 接管配置至 H5 renderReady 的可见加载；移除或失败时对应标识结束。
    /// 后台预加载不通知。未设置时沿用 SDK 默认 UI，已有调用保持兼容。
    public func onPaywallLoadingChange(_ handler: @escaping @MainActor (PaywallLoadingState) -> Void) -> some View {
        environment(\.paywallLoadingHandler, handler)
    }
}
