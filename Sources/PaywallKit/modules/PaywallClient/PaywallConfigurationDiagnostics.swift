import Foundation

/// 配置接口仅在显式 Test 环境记录请求和原始返回，不输出请求头。
enum PaywallConfigurationDiagnostics {
    /// 保持原网络调用和错误传播，用同一标识关联请求、响应及传输错误。
    static func data(for request: URLRequest, environment: String) async throws -> (Data, URLResponse) {
        guard environment == "test" else { return try await URLSession.shared.data(for: request) }
        let identifier = UUID().uuidString
        let started = Date()
        WebPaywallDiagnostics.log(environment, "configuration.request",
            "id=\(identifier) method=\(request.httpMethod ?? "GET") url=\(request.url?.absoluteString ?? "")")
        payload(request.httpBody ?? Data(), event: "configuration.request.body", identifier: identifier)
        do {
            // 在任何业务解析前打印原始响应，非 200 或无效 JSON 同样可见。
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            WebPaywallDiagnostics.log(environment, "configuration.response",
                "id=\(identifier) status=\(status) bytes=\(data.count) durationMs=\(Int(Date().timeIntervalSince(started) * 1000))")
            payload(data, event: "configuration.response.body", identifier: identifier)
            return (data, response)
        } catch {
            // 网络失败保留原始错误，仍由配置来源决定是否读取缓存。
            let failure = error as NSError
            WebPaywallDiagnostics.log(environment, "configuration.request.failed",
                "id=\(identifier) domain=\(failure.domain) code=\(failure.code) message=\(failure.localizedDescription)")
            throw error
        }
    }

    /// 原文分段打印以避免系统单条日志截断，空响应和非 UTF-8 内容明确标记。
    private static func payload(_ data: Data, event: String, identifier: String) {
        guard !data.isEmpty else {
            WebPaywallDiagnostics.log("test", event, "id=\(identifier) body=<empty>")
            return
        }
        guard let text = String(data: data, encoding: .utf8) else {
            WebPaywallDiagnostics.log("test", event, "id=\(identifier) body=<non-UTF8> bytes=\(data.count)")
            return
        }
        // 以 Unicode 标量分段，避免拆坏中文；每段最多约 720 字节。
        let scalars = Array(text.unicodeScalars)
        let chunkSize = 180
        let total = (scalars.count + chunkSize - 1) / chunkSize
        for offset in stride(from: 0, to: scalars.count, by: chunkSize) {
            let chunk = String(String.UnicodeScalarView(scalars[offset..<min(offset + chunkSize, scalars.count)]))
            WebPaywallDiagnostics.log("test", event,
                "id=\(identifier) part=\(offset / chunkSize + 1)/\(total) body=\(chunk)")
        }
    }
}
