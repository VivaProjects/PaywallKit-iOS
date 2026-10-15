import Foundation

/// 通用渠道状态，不依赖具体归因 SDK，也不向 H5 注入渠道信息。
@MainActor
final class PaywallQueryAttribution {
    private let key: String
    private(set) var channel: String?
    var onChange: (() -> Void)?

    /// 复用已确认的归因，避免每次冷启动等待 SDK 重复回调。
    init(namespace: String) {
        key = "paywall.query.attribution.v1.\(namespace)"
        channel = UserDefaults.standard.string(forKey: key)
    }

    /// 已知来源原样保留；成功自然量持久化，失败默认值只在本次进程使用。
    func update(channel: String?, failed: Bool) {
        let previous = self.channel
        if failed {
            if self.channel == nil { self.channel = "organic" }
        } else {
            let resolved = channel.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? "organic"
            self.channel = resolved
            UserDefaults.standard.set(resolved, forKey: key)
        }
        if previous != self.channel { onChange?() }
    }

    /// 首次未知归因最多等五秒；取消立即退出，超时默认值不持久化。
    func resolve() async throws -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while channel == nil && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try Task.checkCancellation()
        return channel ?? "organic"
    }
}
