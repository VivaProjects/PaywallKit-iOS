/// 宿主应用显式选择的运行环境，与商店 Sandbox、编译模式及地区无关。
public enum WebPaywallRuntimeEnvironment: String, Codable, Sendable {
    case test
    case production
}
