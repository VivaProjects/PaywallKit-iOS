import Foundation

/// SDK 全局诊断开关，与请求、商品和缓存使用的运行环境独立。
public enum PaywallLogging {
    public enum Mode: Sendable {
        /// 保持默认行为：仅 test 环境输出日志。
        case automatic
        /// 所有运行环境均输出日志。
        case enabled
        /// 所有运行环境均关闭日志。
        case disabled
    }

    private static let storage = Storage()

    /// 线程安全地读取或设置日志模式；建议在创建 Client 前配置。
    public static var mode: Mode {
        get { storage.read() }
        set { storage.write(newValue) }
    }

    /// 按显式模式判断输出权限，不改变任何业务环境配置。
    static func isEnabled(for environment: String) -> Bool {
        switch mode {
        case .automatic: return environment == "test"
        case .enabled: return true
        case .disabled: return false
        }
    }

    /// 所有可变状态均由锁保护，允许网络任务与宿主并发读写。
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Mode = .automatic

        /// 在锁内读取当前模式。
        func read() -> Mode {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        /// 在锁内更新当前模式。
        func write(_ mode: Mode) {
            lock.lock()
            defer { lock.unlock() }
            value = mode
        }
    }
}
