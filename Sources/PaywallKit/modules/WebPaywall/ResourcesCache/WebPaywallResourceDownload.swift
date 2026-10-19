import Foundation

/// 资源下载禁止重定向；文档来源已由宿主白名单验证。
final class WebPaywallResourceDownload: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// 仅对临时超时最多重试两次，所有尝试与退避共用调用方的整包截止时间。
    func fetch(_ url: URL, limit: Int, deadline: Date) async throws -> Data {
        var retries = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await fetchAttempt(url, limit: limit, deadline: deadline)
            } catch {
                // 取消、HTTP 错误和资源校验错误不进入重试。
                try Task.checkCancellation()
                guard let networkError = error as? URLError,
                      networkError.code == .timedOut, retries < 2 else { throw error }
                let delay: TimeInterval = retries == 0 ? 0.5 : 1
                guard deadline.timeIntervalSinceNow > delay else { throw error }
                retries += 1
                // 退避可被取消；下次尝试重新计算剩余预算，不延长截止时间。
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// 单次请求放宽等待上限，保留响应体限制、来源检查和独立资源释放。
    private func fetchAttempt(_ url: URL, limit: Int, deadline: Date) async throws -> Data {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw URLError(.timedOut) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = min(30, remaining)
        config.timeoutIntervalForResource = remaining
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // 禁止使用不明版本的系统 HTTP 缓存。
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: min(30, remaining))
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url == url, response.expectedContentLength <= Int64(limit)
        else { throw URLError(.badServerResponse) }
        var result = Data()
        for try await byte in bytes {
            guard result.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            if result.count % 8192 == 0, Date() >= deadline { throw URLError(.timedOut) }
            result.append(byte)
        }
        try Task.checkCancellation()
        guard Date() < deadline else { throw URLError(.timedOut) }
        return result
    }

    /// 包内资源不得通过服务端跳转扩大来源或目录权限。
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
