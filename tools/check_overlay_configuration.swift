import Foundation

@main
struct OverlayConfigurationCheck {
    /// 使用真实配置解析器验证完整点位映射，测试无需 UIKit 或模拟器。
    static func main() throws {
        let catalog = PaywallCatalog(productRefs: ["product"], recommendedRef: "product")
        for mode in ["fullScreen", "halfSheet", "halfSheetLocked", "push", "overlay"] {
            let source = """
            {"version":1,"placements":{"offer":"page"},"preload":["page"],
             "presentations":{"offer":"\(mode)"},"paywalls":{"page":{
               "kind":"web-paywall","bridgeVersion":2,"documentId":"page","revision":1,
               "pageUrl":"https://example.com/offer/index.html","catalogKey":"default",
               "productRefs":["product"],"initialProductRef":"product"}}}
            """
            let configuration = try WebPaywallConfiguration(data: Data(source.utf8),
                allowedOrigins: ["https://example.com"], catalogs: ["default": catalog])
            precondition(configuration.presentations["offer"]?.rawValue == mode)
            precondition(configuration.document(forPlacement: "offer")?.productRefs == ["product"])
            precondition(configuration.preloadDocuments.count == 1)
        }
        let legacy = Data(#"{"version":1,"placements":{"offer":"page"}}"#.utf8)
        let legacyModes = try WebPaywallConfiguration.presentationModes(in: legacy)
        precondition(legacyModes["offer"] == .fullScreen)
        for source in [
            #"{"version":1,"placements":{"offer":"page"},"presentations":{"offer":"unknown"}}"#,
            #"{"version":1,"placements":{"offer":"page"},"presentations":{"missing":"overlay"}}"#
        ] {
            do {
                _ = try WebPaywallConfiguration.presentationModes(in: Data(source.utf8))
                fatalError("Invalid mode or placement accepted")
            } catch WebPaywallError.invalidDocument { }
        }
        print("PASS Swift overlay/legacy configuration, page binding, preload and invalid-mode rejection")
    }
}
