import Foundation

/// 模拟服务端下发的入口映射；每个页面继续使用既有 WebPaywallDocument 协议。
public struct WebPaywallConfiguration {
    public enum Presentation: String {
        case fullScreen, halfSheet, halfSheetLocked, push
    }

    public let disabledPlacements: Set<String>
    public let version: Int
    public let placements: [String: String]
    public let presentations: [String: Presentation]
    public let preloadIds: [String]
    public let sessions: [String: WebPaywallSessionPolicy]
    private let documents: [String: WebPaywallDocument]
    var historySnapshot: PaywallHistorySnapshot? = nil

    /// 校验整份配置后冻结页面映射，避免展示期间读到半更新的数据。
    public init(data: Data, allowedOrigins: Set<String>?, catalogs: [String: PaywallCatalog],
                developmentHTTPOrigin: String? = nil) throws {
        guard data.count <= 1_000_000,
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(raw.keys).isSubset(of: Set(["version", "placements", "preload", "paywalls", "presentations", "sessions", "sheetAspectRatios", "disabledPlacements"])),
              let version = raw["version"] as? Int, version == 1,
              let placements = raw["placements"] as? [String: String],
              let preloadIds = raw["preload"] as? [String],
              preloadIds.count == Set(preloadIds).count,
              let paywalls = raw["paywalls"] as? [String: [String: Any]],
              paywalls.count <= 8,
              placements.values.allSatisfy({ paywalls[$0] != nil }),
              preloadIds.allSatisfy({ paywalls[$0] != nil })
        else { throw WebPaywallError.invalidDocument }

        var parsed: [String: WebPaywallDocument] = [:]
        for (identifier, payload) in paywalls {
            guard payload["documentId"] as? String == identifier,
                  let catalogKey = payload["catalogKey"] as? String,
                  let catalog = catalogs[catalogKey],
                  JSONSerialization.isValidJSONObject(payload)
            else { throw WebPaywallError.invalidDocument }
            let documentData = try JSONSerialization.data(withJSONObject: payload)
            parsed[identifier] = try WebPaywallDocument(
                data: documentData, allowedOrigins: allowedOrigins, catalog: catalog,
                developmentHTTPOrigin: developmentHTTPOrigin)
        }
        let disabled = raw["disabledPlacements"] as? [String] ?? []
        guard raw["disabledPlacements"] == nil || raw["disabledPlacements"] is [String],
              disabled.count == Set(disabled).count else { throw WebPaywallError.invalidDocument }
        self.disabledPlacements = Set(disabled)
        self.version = version
        self.placements = placements
        self.presentations = try Self.presentationModes(in: data)
        self.preloadIds = preloadIds
        self.documents = parsed
        self.sessions = try WebPaywallSessionPolicy.parse(raw["sessions"], placements: placements, documents: parsed)
    }

    /// 独立读取下发配置中的原生展示方式，供内置页面宿主复用同一协议。
    public static func presentationModes(in data: Data) throws -> [String: Presentation] {
        guard data.count <= 1_000_000,
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = raw["version"] as? Int, version == 1,
              let placements = raw["placements"] as? [String: String]
        else { throw WebPaywallError.invalidDocument }
        // 旧配置未下发展示方式时，沿用全屏；未知入口或枚举值拒绝加载。
        guard let value = raw["presentations"] else {
            return placements.mapValues { _ in .fullScreen }
        }
        guard let modes = value as? [String: String],
              modes.keys.allSatisfy({ placements[$0] != nil })
        else { throw WebPaywallError.invalidDocument }
        var result = placements.mapValues { _ in Presentation.fullScreen }
        for (placement, value) in modes {
            guard let mode = Presentation(rawValue: value) else { throw WebPaywallError.invalidDocument }
            result[placement] = mode
        }
        return result
    }

    /// 入口只选择已校验的页面，不允许网页自行指定另一个商品目录。
    public func document(forPlacement placement: String) -> WebPaywallDocument? {
        guard let identifier = placements[placement] else { return nil }
        return documents[identifier]
    }

    /// 返回配置允许提前加载的页面，重复入口只加载一次。
    public var preloadDocuments: [WebPaywallDocument] {
        preloadIds.compactMap { documents[$0] }
    }
}
