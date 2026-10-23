import Foundation
import StoreKit

/// 配置接口的环境条件与扩展参数；扩展值仅用于请求，不注入 H5。
public struct PaywallRequestParameters {
    public let environment: WebPaywallEnvironmentConfiguration
    public let additional: [String: String]

    /// 未指定的条件沿用 SDK 环境值；country 覆盖值必须来自当前商店账户。
    public init(language: String? = nil, deviceModel: String? = nil,
                country: String? = nil, appVersion: String? = nil,
                runtimeEnvironment: WebPaywallRuntimeEnvironment = .test,
                additional: [String: String] = [:], os: String = "iOS", isPad: Bool? = nil) {
        environment = WebPaywallEnvironmentConfiguration(
            language: language, deviceModel: deviceModel, country: country, appVersion: appVersion,
            runtimeEnvironment: runtimeEnvironment, os: os, isPad: isPad
        )
        self.additional = additional
    }

    /// 共用 H5 环境采集逻辑，国家仅从 StoreKit 获取，未知时传空字符串。
    @MainActor
    private func values() async throws -> [String: String] {
        let country: String
        if let configured = environment.country { country = configured.uppercased() }
        else { country = (await Storefront.current?.countryCode)?.uppercased() ?? "" }
        guard country.isEmpty || (country.utf8.count == 3 && country.utf8.allSatisfy({ (65...90).contains($0) })) else {
            throw WebPaywallError.invalidDocument
        }
        var standard = WebPaywallEnvironment.capture(country: country, configuration: environment).payload.mapValues { String(describing: $0) }
        // 整份配置请求尚无当前点位；点位只在具体 H5 会话注入。
        standard.removeValue(forKey: "placement")
        // 扩展字段不能覆盖标准环境条件，避免路由条件在字典合并时被悄悄替换。
        guard additional.keys.allSatisfy({ !$0.isEmpty && standard[$0] == nil }) else {
            throw WebPaywallError.invalidDocument
        }
        return standard.merging(additional, uniquingKeysWith: { first, _ in first })
    }

    /// 用 URLComponents 编码并排序参数，字典顺序不影响请求与离线缓存身份。
    @MainActor
    func request(endpoint: String) async throws -> URLRequest {
        guard var components = URLComponents(string: endpoint),
              ["https", "http"].contains(components.scheme ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil else {
            throw WebPaywallError.invalidDocument
        }
        var parameters = try await values()
        // 接口地址允许携带固定参数，但拒绝重复键和覆盖显式配置的参数。
        for item in components.queryItems ?? [] {
            guard !item.name.isEmpty, parameters[item.name] == nil else {
                throw WebPaywallError.invalidDocument
            }
            parameters[item.name] = item.value ?? ""
        }
        components.queryItems = parameters.keys.sorted().map {
            URLQueryItem(name: $0, value: parameters[$0])
        }
        // URLComponents 保留的加号在部分服务端被当作空格，显式转义以保持参数原值。
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw WebPaywallError.invalidDocument }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12
        return request
    }
}
