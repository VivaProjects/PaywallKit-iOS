import Foundation

/// 历史页冻结完整配置与请求身份，不保存商店价格、用户资格或交易对象。
struct PaywallHistorySnapshot: Codable {
    let namespace: String
    let requestURL: String
    let environment: String
    let configuration: Data

    /// 同请求、同环境、同点位和同文档才允许查找历史版本。
    func key(placement: String, documentID: String) -> String {
        let components = [namespace, requestURL, environment, placement, documentID]
        return WebPaywallPackage.digest((try? JSONEncoder().encode(components)) ?? Data())
    }
}
