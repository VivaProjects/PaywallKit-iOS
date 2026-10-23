import Foundation
import OSLog

/// 按独立日志模式输出诊断，并保留真实运行环境标签。
enum WebPaywallDiagnostics {
    /// 统一事件前缀，过滤换行以保证每条事件占一行。
    static func log(_ environment: String, _ event: String, _ detail: @autoclosure () -> String = "") {
        guard PaywallLogging.isEnabled(for: environment) else { return }
        let line = "[PaywallKit][\(environment)] \(event) \(detail())"
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        Logger(subsystem: "PaywallKit", category: "Lifecycle").notice("\(line, privacy: .public)")
    }
}
