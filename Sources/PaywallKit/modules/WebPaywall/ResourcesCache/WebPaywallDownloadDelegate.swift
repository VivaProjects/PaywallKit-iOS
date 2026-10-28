import Foundation

/// 连接池中的请求分别持有缓冲区和截止时间；所有结果只完成一次。
final class WebPaywallDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Entry {
        let task: URLSessionDataTask
        let url: URL
        let limit: Int
        let deadline: Date
        let continuation: CheckedContinuation<Data, Error>
        let timeout: DispatchWorkItem
        var data = Data()
        var acceptedResponse = false
    }
    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]

    /// 先注册再启动，确保响应、超时和提前取消都能找到同一所有者。
    func register(_ task: URLSessionDataTask, url: URL, limit: Int, deadline: Date,
                  continuation: CheckedContinuation<Data, Error>) {
        let identifier = task.taskIdentifier
        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(identifier, error: URLError(.timedOut))
        }
        lock.lock()
        entries[task.taskIdentifier] = Entry(task: task, url: url, limit: limit, deadline: deadline,
                                             continuation: continuation, timeout: timeout)
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: timeout)
    }

    /// 只取消对应资源，同包其他下载仍按自己的生命周期运行。
    func cancel(_ identifier: Int) { finish(identifier, error: CancellationError()) }

    /// 原子移除后在锁外回收并恢复等待者，迟到的回调不会重复完成。
    private func finish(_ identifier: Int, error: Error?) {
        lock.lock()
        let entry = entries.removeValue(forKey: identifier)
        lock.unlock()
        guard let entry else { return }
        entry.timeout.cancel()
        if let error {
            entry.task.cancel()
            entry.continuation.resume(throwing: error)
        } else if Date() >= entry.deadline {
            entry.continuation.resume(throwing: URLError(.timedOut))
        } else if !entry.acceptedResponse {
            entry.continuation.resume(throwing: URLError(.badServerResponse))
        } else {
            entry.continuation.resume(returning: entry.data)
        }
    }

    /// 响应头必须匹配原始 URL、状态和大小，未知长度仍在每个数据块上限流。
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        guard let entry = entries[dataTask.taskIdentifier] else {
            lock.unlock(); completionHandler(.cancel); return
        }
        let error: Error?
        if Date() >= entry.deadline { error = URLError(.timedOut) }
        else if let http = response as? HTTPURLResponse, http.url == entry.url,
                response.expectedContentLength <= Int64(entry.limit) {
            error = http.statusCode == 200 ? nil : PaywallQueryRetry.HTTPFailure(status: http.statusCode)
        } else { error = URLError(.badServerResponse) }
        if error == nil { entries[dataTask.taskIdentifier]?.acceptedResponse = true }
        lock.unlock()
        if let error { finish(dataTask.taskIdentifier, error: error) }
        completionHandler(error == nil ? .allow : .cancel)
    }

    /// 按数据块追加，不因未知 Content-Length 或单个大块突破文件大小上限。
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let identifier = dataTask.taskIdentifier
        guard entries[identifier] != nil else { lock.unlock(); return }
        // 只读取标量再原位追加，避免复制 Data 快照导致每个数据块触发整段拷贝。
        let error: Error?
        if Date() >= entries[identifier]!.deadline { error = URLError(.timedOut) }
        else if data.count > entries[identifier]!.limit - entries[identifier]!.data.count {
            error = URLError(.dataLengthExceedsMaximum)
        } else { error = nil; entries[identifier]?.data.append(data) }
        lock.unlock()
        if let error { finish(dataTask.taskIdentifier, error: error) }
    }

    /// 网络失败和正常结束统一完成，重试由上层沿用原有规则。
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(task.taskIdentifier, error: error)
    }

    /// 包内资源不能借重定向扩大来源或绕过清单。
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
