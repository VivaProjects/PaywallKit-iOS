import Foundation

public struct PaywallRemoteOptions {
    public let baseURL: URL
    public let app: String
    public let environment: String
    public let publicKeys: [String: Data]
    public let cacheDirectory: URL
    public let allowLoopbackHTTP: Bool

    public init(baseURL: URL, app: String, environment: String, publicKeys: [String: Data],
                cacheDirectory: URL, allowLoopbackHTTP: Bool = false) {
        self.baseURL = baseURL
        self.app = app
        self.environment = environment
        self.publicKeys = publicKeys
        self.cacheDirectory = cacheDirectory
        self.allowLoopbackHTTP = allowLoopbackHTTP
    }
}
