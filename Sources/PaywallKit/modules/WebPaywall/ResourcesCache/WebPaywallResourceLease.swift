import Foundation

/// 页面持有期间锁定目录，清理缓存不会删除仍在使用的资源。
public final class WebPaywallResourceLease: @unchecked Sendable {
    public let pageURL: URL
    public let readAccessURL: URL
    private let release: @Sendable () -> Void

    init(directory: URL, release: @escaping @Sendable () -> Void) {
        pageURL = directory.appendingPathComponent("offline.html")
        readAccessURL = directory
        self.release = release
    }

    deinit { release() }
}
