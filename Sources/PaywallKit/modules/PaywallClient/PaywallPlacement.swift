import SwiftUI

/// 页面与展示方式在同一次解析中冻结，宿主不再传递原始 JSON。
public struct PaywallPlacement {
    public let name: String
    public let document: WebPaywallDocument
    public let presentation: WebPaywallConfiguration.Presentation
    public let sessionPolicy: WebPaywallSessionPolicy?
    let clientID: UUID
    var fallbackContext: PaywallFallbackContext? = nil
    var historySnapshot: PaywallHistorySnapshot? = nil
    // 查询启动快照保留远端身份用于历史归档，租约保护当前使用的完整本地包。
    var remoteDocument: WebPaywallDocument? = nil
    var resourceLease: WebPaywallResourceLease? = nil
}

// 保持 Swift 5.9 包兼容，不依赖新工具链的 Environment 宏。
private struct PaywallPlacementKey: EnvironmentKey {
    static let defaultValue: PaywallPlacement? = nil
}

extension EnvironmentValues {
    var paywallPlacement: PaywallPlacement? {
        get { self[PaywallPlacementKey.self] }
        set { self[PaywallPlacementKey.self] = newValue }
    }
}

/// 网页完整内容高度由展示宿主消费，具体业务无需维护 PreferenceKey。
struct PaywallContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}
