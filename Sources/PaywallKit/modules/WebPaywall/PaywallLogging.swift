import Foundation

/// SDK 自动保存日志；开关只控制控制台打印，不影响记录与诊断回调。
public enum PaywallLogging {
    /// 兼容旧调用：automatic 和 disabled 均不打印，所有模式均自动记录。
    public enum Mode: Sendable { case automatic, enabled, disabled }
    private static let storage = Storage()
    private static let logs = PaywallLogStore()

    /// 默认不打印；日志在 test 与 production 中均独立保存。
    public static var printsToConsole: Bool {
        get { storage.read() }
        set { storage.write(newValue) }
    }

    /// 保留源代码兼容；推荐使用布尔打印开关。
    public static var mode: Mode {
        get { printsToConsole ? .enabled : .disabled }
        set { printsToConsole = newValue == .enabled }
    }

    static func isEnabled(for environment: String) -> Bool { printsToConsole }
    static func record(_ line: String) { logs.append(line) }

    /// 等待已有写入并按时间顺序读取日志，关闭打印也可分析。
    public static func read() async -> String { await logs.read() }

    /// 返回可分享的私有日志快照，不自动上传或发送。
    public static func export() async throws -> URL { try await logs.export() }

    /// 清理已保存日志，之后的新日志仍自动记录。
    public static func clear() async throws { try await logs.clear() }

    /// 打印配置由锁保护，与串行磁盘队列互不阻塞。
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func read() -> Bool {
            lock.lock(); defer { lock.unlock() }; return value
        }
        func write(_ value: Bool) {
            lock.lock(); defer { lock.unlock() }; self.value = value
        }
    }
}
