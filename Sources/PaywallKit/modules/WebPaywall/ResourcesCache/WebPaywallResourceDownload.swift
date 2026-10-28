import Foundation

/// 资源下载禁止重定向；文档来源已由宿主白名单验证。
final class WebPaywallResourceDownload: @unchecked Sendable {
    private let delegate = WebPaywallDownloadDelegate()
    private let session: URLSession

    /// 独立包持有连接池；禁用响应缓存，重试及并发资源复用同一会话。
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit { close() }

    /// 所有者结束整个包时关闭会话；单个调用者取消只结束对应数据任务。
    func close() { session.invalidateAndCancel() }

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

    /// 分块接收且逐块限制长度；绝对截止时间覆盖响应头和整个响应体。
    private func fetchAttempt(_ url: URL, limit: Int, deadline: Date) async throws -> Data {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw URLError(.timedOut) }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: min(30, remaining))
        let cancellation = WebPaywallDownloadCancellation()
        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                delegate.register(task, url: url, limit: limit, deadline: deadline, continuation: continuation)
                cancellation.install { [delegate] in delegate.cancel(task.taskIdentifier) }
                task.resume()
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        return data
    }
}
