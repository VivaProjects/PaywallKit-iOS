import Foundation

/// 宿主环境决定缓存目录；文件仓库本身只负责指定目录的完整性。
extension PaywallQuerySnapshotStore {
    /// 环境、接口、应用版本及稳定设备条件隔离；渠道和国家保留在各自请求身份中。
    convenience init(configuration: PaywallQueryConfiguration) {
        let scope = [configuration.cacheScope, configuration.endpoint.absoluteString,
                     Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                     WebPaywallEnvironment.deviceModelIdentifier(), Locale.preferredLanguages.first ?? ""]
        let key = WebPaywallPackage.digest((try? JSONEncoder().encode(scope)) ?? Data())
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaywallKit/QuerySnapshots/\(key)", isDirectory: true)
        self.init(directory: directory, environment: configuration.runtimeEnvironment.rawValue)
    }

}
