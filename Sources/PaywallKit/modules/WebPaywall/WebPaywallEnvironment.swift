import Darwin
import Foundation
import UIKit

/// H5 适配所需的非商业环境信息；不包含设备唯一标识。
struct WebPaywallEnvironment {
    var os: String = "iOS"
    var isPad: Bool = false
    let placement: String
    let runtimeEnvironment: WebPaywallRuntimeEnvironment
    let language: String
    let deviceModel: String
    let country: String
    let appVersion: String

    /// 输出桥接适配字段，保留 isPad 的 JSON 布尔类型。
    var payload: [String: Any] {
        ["os": os, "isPad": isPad, "placement": placement, "runtimeEnvironment": runtimeEnvironment.rawValue, "language": language, "deviceModel": deviceModel,
         "country": country, "appVersion": appVersion]
    }

    /// 将环境字段平铺到 custom；同名字段以已冻结的 SDK 环境为准。
    func customPayload(_ custom: [String: WebPaywallJSONValue]) -> [String: Any] {
        custom.mapValues(\.foundationValue).merging(payload) { _, environment in environment }
    }

    /// 在本次展示会话中冻结环境值，避免页面与预加载缓存读到不同版本。
    @MainActor
    static func capture(country: String, configuration: WebPaywallEnvironmentConfiguration) -> Self {
        let defaultLanguage = Locale.preferredLanguages.first ??
            Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let defaultVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return Self(os: configuration.os, isPad: configuration.isPad ?? (UIDevice.current.userInterfaceIdiom == .pad),
                    placement: configuration.placement, runtimeEnvironment: configuration.runtimeEnvironment,
                    language: configuration.language ?? defaultLanguage,
                    deviceModel: configuration.deviceModel ?? deviceModelIdentifier(),
                    country: country,
                    appVersion: configuration.appVersion ?? defaultVersion)
    }
    /// 查询接口与 H5 共用具体硬件机型，模拟器返回所模拟的设备而非主机架构。
    static func deviceModelIdentifier() -> String {
        #if targetEnvironment(simulator)
        let simulatorModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
        return simulatorModel.flatMap { $0.isEmpty ? nil : $0 } ?? "Simulator"
        #else
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: system.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        #endif
    }
}
