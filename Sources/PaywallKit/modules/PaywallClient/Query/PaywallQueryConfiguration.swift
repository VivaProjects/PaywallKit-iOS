import Foundation

/// 查询接口接入声明；协议细节、设备条件和缓存生命周期由 SDK 管理。
public struct PaywallQueryConfiguration {
    let endpoint: URL
    let runtimeEnvironment: WebPaywallRuntimeEnvironment
    let cacheNamespace: String
    let allowedOrigins: Set<String>?
    let placements: [String: String]
    let fallback: PaywallQueryFallback?
    let developmentHTTPOrigin: String?
    let waitUntilNetworkAvailable: (@Sendable () async throws -> Void)?

    /// SDK 强制按商品运行环境隔离，宿主复用 namespace 也不会串配置或归因。
    var cacheScope: String { "\(cacheNamespace).\(runtimeEnvironment.rawValue)" }

    /// 点位映射与来源由宿主声明；可注入支持取消的联网等待，未传时沿用直接请求。
    public init(endpoint: URL, runtimeEnvironment: WebPaywallRuntimeEnvironment,
                cacheNamespace: String, allowedOrigins: Set<String>?,
                placements: [String: String], fallback: PaywallQueryFallback? = nil,
                developmentHTTPOrigin: String? = nil,
                waitUntilNetworkAvailable: (@Sendable () async throws -> Void)? = nil) {
        self.endpoint = endpoint
        self.runtimeEnvironment = runtimeEnvironment
        self.cacheNamespace = cacheNamespace
        self.allowedOrigins = allowedOrigins
        self.placements = placements
        self.fallback = fallback
        self.waitUntilNetworkAvailable = waitUntilNetworkAvailable
        #if DEBUG
        self.developmentHTTPOrigin = runtimeEnvironment == .test ? developmentHTTPOrigin : nil
        #else
        self.developmentHTTPOrigin = nil
        #endif
    }
}
