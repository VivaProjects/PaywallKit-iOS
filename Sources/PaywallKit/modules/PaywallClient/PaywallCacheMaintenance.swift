import Foundation

/// 调试维护入口：冷启动清理持久化缓存，避免运行中的租约和下载受到影响。
@MainActor
public enum PaywallCacheMaintenance {
    private static let resetKey = "paywall.maintenance.clearOnNextLaunch"

    /// 安排下次进程首次创建查询 Client 前清理，当前会话继续使用原版本。
    public static func clearOnNextLaunch() {
        prepareQueryClient()
        UserDefaults.standard.set(true, forKey: resetKey)
    }

    /// 当前进程仅消费一次，点击维护按钮后必须冷启动才能执行清理。
    static func prepareQueryClient() {
        _ = startupCleanup
    }

    private static let startupCleanup: Void = {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: resetKey) else { return }
        do {
            // 先移除所有 SDK 页面包、启动快照和历史版本，再移除旧配置迁移来源。
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PaywallKit", isDirectory: true)
            if FileManager.default.fileExists(atPath: root.path) {
                // 页面缓存清理保留独立诊断记录，日志仅由 PaywallLogging.clear 清理。
                for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                    where child.lastPathComponent != "Diagnostics" {
                    try FileManager.default.removeItem(at: child)
                }
            }
            for key in defaults.dictionaryRepresentation().keys
                where key.hasPrefix("paywall.configuration.v1.") || key.hasPrefix("paywall.configuration.v2.") {
                defaults.removeObject(forKey: key)
            }
            defaults.removeObject(forKey: resetKey)
        } catch {
            // 保留标记，下次启动继续尝试；不得误报清理成功。
            WebPaywallDiagnostics.log("sdk", "maintenance.cleanup_failed", "code=\((error as NSError).code)")
        }
    }()
}
