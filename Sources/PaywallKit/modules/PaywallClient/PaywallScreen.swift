import SwiftUI

/// 点位级页面：统一会话、加载、错误重试、Host、网页缓存和内容高度报告。
@MainActor
public struct PaywallScreen: View {
    @Environment(\.paywallPlacement) private var resolvedPlacement
    @Environment(\.paywallPreparedPage) private var preparedPage
    private let isPresented: Bool
    private let localPackages: PaywallLocalPackageStore?
    private let client: PaywallClient
    private let placement: String
    private let validityIdentity: AnyHashable
    private let cacheIdentity: AnyHashable
    private let canDismiss: () -> Bool
    private let copy: PaywallRuntimeCopy
    private let prepare: (WebPaywallDocument) async throws -> PaywallSessionInput
    private let prepareCached: ((WebPaywallDocument) throws -> PaywallSessionInput)?
    private let openLegal: (PaywallHost.LegalRoute) -> Void
    private let onEvent: (PaywallSessionEvent) -> Void

    public init(client: PaywallClient, placement: String,
                validityIdentity: AnyHashable, cacheIdentity: AnyHashable,
                isPresented: Bool = true, localPackages: PaywallLocalPackageStore? = nil,
                canDismiss: @escaping () -> Bool = { true }, copy: PaywallRuntimeCopy = .init(),
                prepare: @escaping (WebPaywallDocument) async throws -> PaywallSessionInput,
                prepareCached: ((WebPaywallDocument) throws -> PaywallSessionInput)? = nil,
                openLegal: @escaping (PaywallHost.LegalRoute) -> Void,
                onEvent: @escaping (PaywallSessionEvent) -> Void) {
        self.isPresented = isPresented
        self.localPackages = localPackages
        self.client = client
        self.placement = placement
        self.validityIdentity = validityIdentity
        self.cacheIdentity = cacheIdentity
        self.canDismiss = canDismiss
        self.copy = copy
        self.prepare = prepare
        self.prepareCached = prepareCached
        self.openLegal = openLegal
        self.onEvent = onEvent
    }

    /// 防止同一展示树中的其他点位误消费本次预渲染会话。
    private var matchingPreparedPage: PaywallPreparedPage? {
        guard let preparedPage, preparedPage.placement.name == placement,
              preparedPage.placement.clientID == client.id else { return nil }
        return preparedPage
    }

    public var body: some View {
        PaywallSessionScreen(client: client, placement: placement, resolvedPlacement: resolvedPlacement,
                             preparedPage: matchingPreparedPage, validityIdentity: validityIdentity,
                             cacheIdentity: cacheIdentity, isPresented: isPresented, localPackages: localPackages, canDismiss: canDismiss, copy: copy,
                             prepare: prepare, prepareCached: prepareCached, openLegal: openLegal, onEvent: onEvent)
    }
}
