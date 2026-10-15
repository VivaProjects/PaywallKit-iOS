import Foundation

public struct PaywallSnapshotFactory {
    public init() {}

    /// 从宿主 Bundle 加载文档，并执行完整的协议与业务校验。
    public func loadBundled(
        name: String = "onboarding", bundle: Bundle? = nil,
        placement: String, locale: String, storefrontGroup: String,
        catalogs: [String: PaywallCatalog], assetIDs: Set<String>
    ) throws -> PaywallSnapshot {
        let source = bundle ?? .module
        guard let url = source.url(forResource: name, withExtension: "json") else {
            throw PaywallValidationError(path: "$", reason: "missing_bundle_document")
        }
        // 先限制磁盘数据大小，再进行 JSON 解码和结构校验。
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 262144 else { throw PaywallValidationError(path: "$", reason: "byte_limit") }
        let data = try Data(contentsOf: url)
        return try makeTrusted(data, placement: placement, locale: locale,
                               storefrontGroup: storefrontGroup, catalogs: catalogs, assetIDs: assetIDs)
    }

    /// 接收宿主提供的 JSON；网络、鉴权与来源完整性由宿主分发层负责。
    public func decodeDocument(
        _ data: Data, placement: String, locale: String, storefrontGroup: String,
        catalogs: [String: PaywallCatalog], assetIDs: Set<String>
    ) throws -> PaywallSnapshot {
        // 数据始终通过固定 Schema 与业务规则，不能直接传入视图。
        try makeTrusted(data, placement: placement, locale: locale,
                        storefrontGroup: storefrontGroup, catalogs: catalogs, assetIDs: assetIDs)
    }

    /// 所有 JSON 入口共用校验，构造后才向渲染器提供不可变快照。
    func makeTrusted(_ data: Data, placement: String, locale: String, storefrontGroup: String,
                     catalogs: [String: PaywallCatalog], assetIDs: Set<String>) throws -> PaywallSnapshot {
        try validateSchema(data)
        let document = try JSONDecoder().decode(PaywallDocument.self, from: data)
        let catalog = try validateBusiness(document, placement, catalogs, assetIDs)
        let resolved = resolveLanguage(document, locale)
        return PaywallSnapshot(document: document, language: resolved.1, locale: resolved.0,
                               storefrontGroup: storefrontGroup, productRefs: catalog.productRefs,
                               recommendedRef: catalog.recommendedRef)
    }

    /// 加载不可变包内 Schema，拒绝所有未注册字段。
    private func validateSchema(_ data: Data) throws {
        guard data.count <= 262144,
              let url = Bundle.module.url(forResource: "paywall.schema", withExtension: "json"),
              let schema = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw PaywallValidationError(path: "$", reason: "missing_schema")
        }
        try SchemaValidator(root: schema).validate(JSONSerialization.jsonObject(with: data))
    }

    /// 在组件构造前检查版本、身份、商品、资源和必需法律入口。
    private func validateBusiness(_ doc: PaywallDocument, _ placement: String,
                                  _ catalogs: [String: PaywallCatalog], _ assets: Set<String>) throws -> PaywallCatalog {
        guard doc.placement == placement, doc.minimumRendererVersion["ios", default: Int.max] <= 1 else {
            throw PaywallValidationError(path: "$.placement", reason: "incompatible_context")
        }
        let nodes = [doc.tree] + (doc.tree.children ?? []) + [doc.bottomBar]
        guard nodes.count <= 80, Set(nodes.map(\.nodeId)).count == nodes.count else {
            throw PaywallValidationError(path: "$.tree", reason: "duplicate_id_or_node_limit")
        }
        try validateCapabilities(doc, nodes)
        try validateContent(doc, nodes, assets)
        let pickers = nodes.filter { $0.type == .productPicker }
        guard pickers.count == 1, nodes.filter({ $0.type == .legalActions }).count == 1,
              nodes.filter({ $0.type == .closeButton }).count <= 1,
              let key = pickers.first?.props.catalogKey, let catalog = catalogs[key],
              !catalog.productRefs.isEmpty, catalog.productRefs.count <= 12,
              catalog.productRefs.allSatisfy({ !$0.isEmpty }),
              Set(catalog.productRefs).count == catalog.productRefs.count,
              catalog.productRefs.contains(catalog.recommendedRef) else {
            throw PaywallValidationError(path: "$.tree.children", reason: "purchase_contract")
        }
        return catalog
    }

    /// 所有使用的组件都需要显式能力声明，缺少任意能力即整页拒绝。
    private func validateCapabilities(_ doc: PaywallDocument, _ nodes: [PaywallNode]) throws {
        guard let url = Bundle.module.url(forResource: "component-catalog", withExtension: "json"),
              let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let components = catalog["components"] as? [[String: Any]] else {
            throw PaywallValidationError(path: "$", reason: "missing_catalog")
        }
        let mapping = Dictionary(uniqueKeysWithValues: components.compactMap { item -> (String, String)? in
            guard let type = item["type"] as? String, let capability = item["capability"] as? String else { return nil }
            return (type, capability)
        })
        let declared = Set(doc.requiredCapabilities)
        guard declared.isSubset(of: Set(mapping.values)),
              nodes.allSatisfy({ declared.contains(mapping[$0.type.rawValue] ?? "") }) else {
            throw PaywallValidationError(path: "$.requiredCapabilities", reason: "unsupported_or_missing_capability")
        }
    }

    /// 默认语言必须完整；翻译可按键回退，图片只能引用宿主白名单。
    private func validateContent(_ doc: PaywallDocument, _ nodes: [PaywallNode], _ assets: Set<String>) throws {
        guard let base = doc.localization.locales[doc.localization.defaultLocale] else {
            throw PaywallValidationError(path: "$.localization.defaultLocale", reason: "missing_default")
        }
        for node in nodes {
            let props = node.props
            for key in [props.textKey, props.altKey, props.titleKey, props.bodyKey, props.labelKey].compactMap({ $0 }) {
                guard base.strings[key] != nil else {
                    throw PaywallValidationError(path: "$.node[\(node.nodeId)]", reason: "missing_text:\(key)")
                }
            }
            if let key = props.itemsKey, base.lists[key] == nil {
                throw PaywallValidationError(path: "$.node[\(node.nodeId)]", reason: "missing_list")
            }
            if let id = props.assetId, !assets.contains(id) {
                throw PaywallValidationError(path: "$.node[\(node.nodeId)]", reason: "unknown_asset")
            }
        }
    }

    /// 合并语言时从默认到精确语言，保留缺失键的确定性回退。
    private func resolveLanguage(_ doc: PaywallDocument, _ requested: String) -> (String, PaywallDocument.Language) {
        let chain = PaywallSnapshot.localeChain(requested, fallback: doc.localization.defaultLocale)
        var strings: [String: String] = [:]
        var lists: [String: [String]] = [:]
        for locale in chain.reversed() {
            if let language = doc.localization.locales[locale] {
                strings.merge(language.strings) { _, translated in translated }
                lists.merge(language.lists) { _, translated in translated }
            }
        }
        return (chain.first(where: { doc.localization.locales[$0] != nil }) ?? doc.localization.defaultLocale,
                .init(strings: strings, lists: lists))
    }
}
