import Foundation

/// 宿主声明内置兜底资源及适用点位，无需创建或维护更新仓库。
public struct PaywallQueryFallback {
    let placement: String
    let bundledDirectory: URL
    let fallbackPlacements: Set<String>
    let previousVersionPlacements: Set<String>

    /// 默认对使用兜底的主动入口保留同页旧版本，可显式收窄范围。
    public init(placement: String, bundledDirectory: URL, fallbackPlacements: Set<String>,
                previousVersionPlacements: Set<String>? = nil) {
        self.placement = placement
        self.bundledDirectory = bundledDirectory
        self.fallbackPlacements = fallbackPlacements
        self.previousVersionPlacements = previousVersionPlacements ?? fallbackPlacements
    }
}
