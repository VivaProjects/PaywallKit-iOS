import Foundation

/// 资源下载禁止重定向；文档来源已由宿主白名单验证。
final class WebPaywallResourceDownload: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// 限制响应体、网络等待与缓存行为，失败由会话回到当前远端页。
    func fetch(_ url: URL, limit: Int, deadline: Date) async throws -> Data {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw URLError(.timedOut) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = min(3, remaining)
        config.timeoutIntervalForResource = remaining
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // 禁止使用不明版本的系统 HTTP 缓存。
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
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
