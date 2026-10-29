import Foundation
import StoreKit

/// 保存最近成功取得的商店国家；运行环境之间不共用兜底值。
@MainActor
enum PaywallStoreCountry {
    /// 只查询一次，空结果使用历史值，不增加重试或延时等待。
    static func resolve(configured: String? = nil,
                        environment: WebPaywallRuntimeEnvironment) async -> String {
        let current: String
        if let configured { current = configured }
        else { current = await Storefront.current?.countryCode ?? "" }
        // 取消的请求不写入缓存，也不继续读取历史国家。
        guard !Task.isCancelled else { return "" }
        let key = "PaywallKit.storeCountry.v1.\(environment.rawValue)"
        let value = current.uppercased()
        if !value.isEmpty {
            // 非空非法值保留给既有调用方校验，不污染成功缓存。
            if valid(value) { UserDefaults.standard.set(value, forKey: key) }
            return value
        }
        let cached = UserDefaults.standard.string(forKey: key) ?? ""
        return valid(cached) ? cached : ""
    }

    /// 仅接受桥协议约定的三位大写国家码。
    private static func valid(_ value: String) -> Bool {
        value.utf8.count == 3 && value.utf8.allSatisfy { (65...90).contains($0) }
    }
}
