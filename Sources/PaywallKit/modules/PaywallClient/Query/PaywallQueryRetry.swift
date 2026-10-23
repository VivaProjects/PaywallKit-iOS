import Foundation

/// 同一后台任务内有限重试，不重采集请求身份，也不取消其他入口的等待。
enum PaywallQueryRetry {
    struct HTTPFailure: Error { let status: Int }

    /// 临时网络错误和可恢复的服务端状态最多尝试三次；校验、权限和取消不重试。
    static func permits(_ error: Error) -> Bool {
        if let failure = error as? HTTPFailure {
            return failure.status == 408 || failure.status == 429 || (500...599).contains(failure.status)
        }
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return true
        default: return false
        }
    }

    /// 退避可取消；联网等待由具体操作提供，入口超时不影响后台重试。
    @MainActor
    static func run<T>(environment: String, stage: String,
                       operation: () async throws -> T) async throws -> T {
        for attempt in 0...2 {
            try Task.checkCancellation()
            do { return try await operation() }
            catch {
                try Task.checkCancellation()
                guard attempt < 2, permits(error) else { throw error }
                let delay: UInt64 = attempt == 0 ? 2 : 5
                WebPaywallDiagnostics.log(environment, "query.retry", "stage=\(stage) attempt=\(attempt + 2) delay=\(delay)")
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }
        throw URLError(.unknown)
    }
}
