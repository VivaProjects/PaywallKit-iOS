import CryptoKit
import Foundation
import StoreKit
import UIKit

/// 业务查询协议独立于 H5 环境；设备使用具体硬件机型，语言和商店国家保留系统原值。
struct PaywallQueryRequest: Codable {
    struct Conditions: Codable {
        let os: String
        let isPad: Bool
        let channel: String
        let version: String
        let device_type: String
        let language: String
        let country: String
    }
    let conditions: Conditions

    /// 先等待归因，再采集当前商店与应用条件，发送稳定编码的 JSON。
    @MainActor
    static func request(configuration: PaywallQueryConfiguration,
                        attribution: PaywallQueryAttribution) async throws -> URLRequest {
        let endpoint = configuration.endpoint
        guard endpoint.scheme == "https" ||
                (endpoint.scheme == "http" && WebPaywallDocument.origin(of: endpoint) == configuration.developmentHTTPOrigin),
              endpoint.host != nil, endpoint.user == nil,
              endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil else {
            throw WebPaywallError.invalidDocument
        }
        // 等待归因后采集商店国家，保持原始国家码。
        let channel = try await WebPaywallDiagnostics.measure(configuration.runtimeEnvironment.rawValue, "query.attribution") {
            try await attribution.resolve()
        }
        let country = await WebPaywallDiagnostics.measure(configuration.runtimeEnvironment.rawValue, "query.storefront") {
            await PaywallStoreCountry.resolve(environment: configuration.runtimeEnvironment)
        }
        try Task.checkCancellation()
        // 复用 H5 的具体硬件机型；首选语言不做翻译或大小写转换。
        let language = Locale.preferredLanguages.first ?? ""
        let body = Self(conditions: Conditions(
            os: "iOS", isPad: UIDevice.current.userInterfaceIdiom == .pad,
            channel: attribution.channel ?? channel,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            device_type: WebPaywallEnvironment.deviceModelIdentifier(),
            language: language, country: country))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try encoder.encode(body)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12
        return request
    }

    /// 完整条件及目标地址参与请求身份，避免 POST 共用 URL 导致串缓存。
    static func identity(_ request: URLRequest, namespace: String) -> String {
        let prefix = "\(namespace)|\(request.httpMethod ?? "")|\(request.url?.absoluteString ?? "")|"
        return SHA256.hash(data: Data(prefix.utf8) + (request.httpBody ?? Data()))
            .map { String(format: "%02x", $0) }.joined()
    }

}
