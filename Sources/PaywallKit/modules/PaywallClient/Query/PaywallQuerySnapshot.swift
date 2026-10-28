import Foundation

/// 按点位保存完整发布身份及原始请求，不持久化价格、权益或交易会话。
struct PaywallQuerySnapshot: Codable {
    let placement: String
    let requestIdentity: String
    let requestBody: Data
    let configuration: Data
    let identity: WebPaywallPackage.Document

    /// 资源按完整发布身份隔离，同文档不同版本或发布地址不得互相覆盖。
    var packageKey: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return WebPaywallPackage.digest((try? encoder.encode(identity)) ?? Data())
    }

}
