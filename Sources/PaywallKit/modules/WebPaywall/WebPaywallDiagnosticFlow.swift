import SwiftUI

/// 仅在原生视图树传递日志关联标识，不参与缓存身份或注入 H5。
private struct WebPaywallDiagnosticFlowKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var webPaywallDiagnosticFlow: String {
        get { self[WebPaywallDiagnosticFlowKey.self] }
        set { self[WebPaywallDiagnosticFlowKey.self] = newValue }
    }
}
