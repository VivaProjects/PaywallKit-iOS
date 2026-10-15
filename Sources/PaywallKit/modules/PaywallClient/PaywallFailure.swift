import Foundation

/// 页面故障与交易、取消和业务失效分离，不通过错误文案推断降级策略。
public enum PaywallFailure: String, Error {
    case configuration, missingPlacement, disabled, resource, bridge, renderTimeout
    case productsUnavailable, cancelled, eligibility

    var permitsFallback: Bool {
        switch self {
        case .configuration, .missingPlacement, .resource, .bridge, .renderTimeout: true
        default: false
        }
    }

    var invalidatesPackage: Bool { self == .resource || self == .bridge }
}
