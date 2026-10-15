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

    /// SDK 强制按商品运行环境隔离，宿主复用 namespace 也不会串配置或归因。
    var cacheScope: String { "\(cacheNamespace).\(runtimeEnvironment.rawValue)" }

    /// 点位映射只接收宿主支持的入口，来源白名单由宿主声明，显式传 nil 表示不限制来源。
    public init(endpoint: URL, runtimeEnvironment: WebPaywallRuntimeEnvironment,
                cacheNamespace: String, allowedOrigins: Set<String>?,
                placements: [String: String], fallback: PaywallQueryFallback? = nil,
                developmentHTTPOrigin: String? = nil) {
        self.endpoint = endpoint
        self.runtimeEnvironment = runtimeEnvironment
        self.cacheNamespace = cacheNamespace
        self.allowedOrigins = allowedOrigins
        self.placements = placements
        self.fallback = fallback
        #if DEBUG
        self.developmentHTTPOrigin = runtimeEnvironment == .test ? developmentHTTPOrigin : nil
        #else
        self.developmentHTTPOrigin = nil
        #endif
    }
}
