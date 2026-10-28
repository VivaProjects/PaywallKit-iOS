import Foundation

/// 配置接口按独立日志模式记录请求和响应摘要，不输出请求头。
enum PaywallConfigurationDiagnostics {
    /// 保持原网络调用和错误传播，用同一标识关联请求、响应及传输错误。
    static func data(for request: URLRequest, environment: String) async throws -> (Data, URLResponse) {
        let identifier = UUID().uuidString
        let started = ProcessInfo.processInfo.systemUptime
        WebPaywallDiagnostics.log(environment, "configuration.request",
            "id=\(identifier) method=\(request.httpMethod ?? "GET")")
        do {
            // 在业务解析前记录状态与大小，原始内容不写入日志。
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            WebPaywallDiagnostics.log(environment, "configuration.response",
                "id=\(identifier) status=\(status) bytes=\(data.count) durationMs=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))")
            return (data, response)
        } catch {
            // 网络失败保留原始错误，仍由配置来源决定是否读取缓存。
            let failure = error as NSError
            WebPaywallDiagnostics.log(environment, "configuration.request.failed",
                "id=\(identifier) domain=\(failure.domain) code=\(failure.code) durationMs=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))")
            throw error
        }
    }

}
