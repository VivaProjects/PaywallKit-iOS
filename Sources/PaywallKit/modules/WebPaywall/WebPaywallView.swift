import Foundation
import SwiftUI
import WebKit

/// 运行 HTTPS 或 App 内置 H5 支付墙；页面故障时交还已有原生支付墙。
@MainActor public struct WebPaywallView<NativeFallback: View>: View {
    public let document: WebPaywallDocument
    public let storefrontGroup: String
    public let host: PaywallHost
    public let environment: WebPaywallEnvironmentConfiguration
    public let custom: [String: WebPaywallJSONValue]
    public let webViewCache: WebPaywallWebViewCache?
    public let preparationDeadline: Date?
    public let isPresented: Bool
    public let onContentHeightChange: ((CGFloat) -> Void)?
    public let onReady: () -> Void
    public let onFailure: ((PaywallFailure) -> Void)?
    public let onResourceSource: ((String) -> Void)?
    public let fallback: () -> NativeFallback
    @State private var failed = false
    @State private var ready = false

    public init(document: WebPaywallDocument, storefrontGroup: String,
                host: PaywallHost,
                environment: WebPaywallEnvironmentConfiguration = .init(),
                custom: [String: WebPaywallJSONValue] = [:],
                webViewCache: WebPaywallWebViewCache? = nil,
                preparationDeadline: Date? = nil, isPresented: Bool = true,
                onContentHeightChange: ((CGFloat) -> Void)? = nil,
                onReady: @escaping () -> Void = {},
                onFailure: ((PaywallFailure) -> Void)? = nil,
                onResourceSource: ((String) -> Void)? = nil,
                @ViewBuilder fallback: @escaping () -> NativeFallback) {
        self.document = document
        self.storefrontGroup = storefrontGroup
        self.host = host
        self.environment = environment
        self.custom = custom
        self.webViewCache = webViewCache
        self.preparationDeadline = preparationDeadline
        self.isPresented = isPresented
        self.onContentHeightChange = onContentHeightChange
        self.onReady = onReady
        self.onFailure = onFailure
        self.onResourceSource = onResourceSource
        self.fallback = fallback
        _ready = State(initialValue: webViewCache?.isReady(for: document,
                                                           storefrontGroup: storefrontGroup,
                                                           environment: environment,
                                                           custom: custom) == true)
    }

    public var body: some View {
        Group {
            if failed { fallback() }
            else {
                ZStack {
                    WebPaywallContainer(document: document, storefrontGroup: storefrontGroup,
                                        host: host, environment: environment,
                                        custom: custom,
                                        webViewCache: webViewCache,
                                        preparationDeadline: preparationDeadline, isPresented: isPresented,
                                        onContentHeightChange: onContentHeightChange,
                                        onReady: { ready = true; onReady() },
                                        onFailure: { failed = true }, onTypedFailure: onFailure,
                                        onResourceSource: onResourceSource)
                        .allowsHitTesting(ready && isPresented)
                        .accessibilityHidden(!ready || !isPresented)
                    if !ready {
                        Color(uiColor: .systemBackground).ignoresSafeArea()
                        VStack(spacing: 20) {
                            ProgressView()
                            if host.allowsDismiss {
                                Button(host.copy.close, action: host.dismiss)
                            }
                        }
                    }
                }
            }
        }
    }
}
