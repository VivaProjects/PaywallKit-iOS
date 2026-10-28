import Foundation
import OSLog

/// 按独立日志模式输出诊断，并保留真实运行环境标签。
enum WebPaywallDiagnostics {
    private static let runID = UUID().uuidString
    /// 阶段计时使用单调时钟，开始和结束共享标识，异常仍原样传播。
    static func measure<T>(_ environment: String, _ stage: String, _ detail: String = "",
                           operation: () async throws -> T) async rethrows -> T {
        let id = UUID().uuidString, started = ProcessInfo.processInfo.systemUptime
        log(environment, stage + ".begin", "span=\(id) \(detail)")
        do {
            let result = try await operation()
            log(environment, stage + ".end", "span=\(id) durationMs=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) status=ok \(detail)")
            return result
        } catch {
            log(environment, stage + ".end", "span=\(id) durationMs=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) status=error code=\((error as NSError).code) \(detail)")
            throw error
        }
    }

    /// 统一事件前缀，过滤换行以保证每条事件占一行。
    static func log(_ environment: String, _ event: String, _ detail: @autoclosure () -> String = "") {
        let line = "[PaywallKit][\(environment)] \(event) sdk=ios run=\(runID) wallMs=\(Int(Date().timeIntervalSince1970 * 1000)) tMs=\(Int(ProcessInfo.processInfo.systemUptime * 1000)) \(detail())"
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        PaywallLogging.record(line)
        if PaywallLogging.printsToConsole {
            Logger(subsystem: "PaywallKit", category: "Lifecycle").notice("\(line, privacy: .public)")
        }
    }
}
