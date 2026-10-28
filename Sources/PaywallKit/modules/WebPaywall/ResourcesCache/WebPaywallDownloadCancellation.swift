import Foundation

/// 处理取消先于数据任务注册的竞态；取消不扩散到同连接池的其他资源。
final class WebPaywallDownloadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var action: (@Sendable () -> Void)?

    /// 安装任务取消动作；已经取消的调用立即结束，不等待网络回调。
    func install(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        let runNow = cancelled
        if !runNow { self.action = action }
        lock.unlock()
        if runNow { action() }
    }

    /// 锁外执行取消，避免与 URLSession 回调形成重入锁等待。
    func cancel() {
        lock.lock()
        cancelled = true
        let action = self.action
        self.action = nil
        lock.unlock()
        action?()
    }
}
