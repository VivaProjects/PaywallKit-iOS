import SwiftUI

private struct WebPaywallSheetLayoutKey: EnvironmentKey {
    static let defaultValue: AnyHashable? = nil
}

extension EnvironmentValues {
    /// 原生 Sheet 的布局身份；只有 detent 配置改变时才重新确定 H5 视口。
    /// 直接使用 WebPaywallView 的宿主可传入当前 detent/选择状态，不向 H5 注入此值。
    public var webPaywallSheetLayoutID: AnyHashable? {
        get { self[WebPaywallSheetLayoutKey.self] }
        set { self[WebPaywallSheetLayoutKey.self] = newValue }
    }
}
