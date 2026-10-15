import Foundation
import OSLog

/// 仅按宿主显式测试环境输出诊断，不依赖编译模式，不记录业务载荷。
enum WebPaywallDiagnostics {
    /// 统一事件前缀，过滤换行以保证每条事件占一行。
    static func log(_ environment: String, _ event: String, _ detail: @autoclosure () -> String = "") {
        guard environment == "test" else { return }
        let line = "[PaywallKit][test] \(event) \(detail())"
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        Logger(subsystem: "PaywallKit", category: "Lifecycle").notice("\(line, privacy: .public)")
    }
}
