import SwiftUI

/// JSON 无法初始化时调用宿主固定原生支付墙，保留其现有购买路径。
@MainActor public struct PaywallEntryView<Fallback: View>: View {
    private let snapshot: PaywallSnapshot?
    private let failure: String?
    private let host: PaywallHost
    private let fallback: () -> Fallback
    private let reportFallback: (String) -> Void
    @State private var reported = false

    public init(host: PaywallHost, load: () throws -> PaywallSnapshot,
                reportFallback: @escaping (String) -> Void,
                @ViewBuilder nativeFallback: @escaping () -> Fallback) {
        self.host = host
        self.fallback = nativeFallback
        self.reportFallback = reportFallback
        do { snapshot = try load(); failure = nil }
        catch { snapshot = nil; failure = String(describing: error) }
    }

    public var body: some View {
        Group {
            if let snapshot {
                PaywallRendererView(snapshot: snapshot, host: host)
            } else {
                fallback().onAppear {
                    guard !reported else { return }
                    reported = true
                    reportFallback(failure ?? "initialization_failed")
                }
            }
        }
    }
}
