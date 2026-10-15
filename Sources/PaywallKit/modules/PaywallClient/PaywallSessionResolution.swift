import Foundation

/// 曝光归属原入口，实际资源与兜底原因单独记录。
public struct PaywallSessionResolution {
    public let requestedPlacement: String
    public let documentID: String
    public let revision: Int
    public let source: String
    public let fallbackReason: String?
}
