import Foundation

/// 共享配置请求不可取消时也能及时结束当前展示，不等待其网络任务返回。
@MainActor
final class PaywallDeadline<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var operation: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var completed = false

    /// 首个结果消费 continuation，超时和取消后的迟到结果全部忽略。
    func run(until deadline: Date, operation work: @escaping @MainActor () async throws -> Value) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled { finish(.failure(CancellationError())); return }
                operation = Task { [weak self] in
                    do { self?.finish(.success(try await work())) }
                    catch { self?.finish(.failure(error)) }
                }
                timer = Task { [weak self] in
                    let seconds = max(0, deadline.timeIntervalSinceNow)
                    do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                    catch { return }
                    self?.finish(.failure(PaywallFailure.renderTimeout))
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    /// 恢复等待者前释放任务句柄，避免取消与完成重复回调。
    private func finish(_ result: Result<Value, Error>) {
        guard !completed else { return }
        completed = true
        operation?.cancel()
        timer?.cancel()
        operation = nil
        timer = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}
