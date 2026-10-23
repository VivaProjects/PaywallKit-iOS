/// 宿主按应用覆盖 H5 适配信息；nil 表示沿用 SDK 的当前值。
/// country 只能填写当前商店账户国家的 ISO 3166-1 alpha-3 大写代码。
public struct WebPaywallEnvironmentConfiguration: Equatable {
    public let os: String
    public let isPad: Bool?
    public let placement: String
    public let runtimeEnvironment: WebPaywallRuntimeEnvironment
    public let language: String?
    public let deviceModel: String?
    public let country: String?
    public let appVersion: String?

    /// 配置会话系统与设备信息，未指定平板类型时自动采集。
    public init(language: String? = nil, deviceModel: String? = nil,
                country: String? = nil, appVersion: String? = nil,
                runtimeEnvironment: WebPaywallRuntimeEnvironment = .test, placement: String = "",
                os: String = "iOS", isPad: Bool? = nil) {
        precondition(["iOS", "Android"].contains(os), "os must be iOS or Android")
        self.os = os
        self.isPad = isPad
        self.placement = placement
        self.runtimeEnvironment = runtimeEnvironment
        self.language = language
        self.deviceModel = deviceModel
        self.country = country
        self.appVersion = appVersion
    }

    /// 高层入口以实际点位覆盖调用方值，其他会话环境保持不变。
    func forPlacement(_ placement: String) -> Self {
        Self(language: language, deviceModel: deviceModel, country: country,
             appVersion: appVersion, runtimeEnvironment: runtimeEnvironment, placement: placement, os: os, isPad: isPad)
    }
}
