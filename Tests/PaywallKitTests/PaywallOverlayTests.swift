import XCTest
import WebKit
@testable import PaywallKit

final class PaywallOverlayTests: XCTestCase {
    /// 新模式必须保留原始配置值，缺省与非法模式继续沿用既有校验。
    func testOverlayConfigurationAndLegacyModes() throws {
        for mode in ["fullScreen", "halfSheet", "halfSheetLocked", "push", "overlay"] {
            let data = Data("""
            {"version":1,"placements":{"offer":"page"},"presentations":{"offer":"\(mode)"}}
            """.utf8)
            let parsed = try WebPaywallConfiguration.presentationModes(in: data)
            XCTAssertEqual(parsed["offer"]?.rawValue, mode)
        }
        let legacy = Data(#"{"version":1,"placements":{"offer":"page"}}"#.utf8)
        XCTAssertEqual(try WebPaywallConfiguration.presentationModes(in: legacy)["offer"], .fullScreen)
        let invalid = Data(#"{"version":1,"placements":{"offer":"page"},"presentations":{"offer":"unknown"}}"#.utf8)
        XCTAssertThrowsError(try WebPaywallConfiguration.presentationModes(in: invalid))
    }

    /// 冷页与缓存均经工厂创建，布局后外层也不能重新盖上白底。
    @MainActor
    func testWebViewAndViewportKeepTransparentBackground() {
        let webView = WebPaywallWebViewFactory.make(configuration: WKWebViewConfiguration())
        XCTAssertFalse(webView.isOpaque)
        XCTAssertEqual(webView.backgroundColor, .clear)
        XCTAssertEqual(webView.scrollView.backgroundColor, .clear)
        XCTAssertEqual(webView.underPageBackgroundColor, .clear)
        let viewport = WebPaywallViewportView(webView: webView, sheetLayoutID: nil)
        XCTAssertFalse(viewport.isOpaque)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(viewport)
        viewport.frame = window.bounds
        viewport.layoutIfNeeded()
        XCTAssertEqual(viewport.backgroundColor, .clear)
    }
}
