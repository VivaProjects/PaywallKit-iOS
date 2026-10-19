import Foundation

/// 包装业务交易适配器，统一发布结果；业务适配器不再直接触发页面关闭。
@MainActor
final class PaywallSessionBridge: PaywallPurchaseBridge {
    var requiresStoreProducts: Bool { base.requiresStoreProducts }
    var allowsStoreActions: Bool { base.allowsStoreActions }

    private let base: any PaywallPurchaseBridge
    private let event: (PaywallSessionEvent) -> Void
    private let isActive: () -> Bool

    init(base: any PaywallPurchaseBridge, isActive: @escaping () -> Bool,
         event: @escaping (PaywallSessionEvent) -> Void) {
        self.base = base
        self.isActive = isActive
        self.event = event
    }

    /// 商品身份与商店查询保持业务适配器原有约束。
    func products(references: [String], storefrontGroup: String) async throws -> [PaywallStoreProduct] {
        guard isActive() else { throw CancellationError() }
        return try await base.products(references: references, storefrontGroup: storefrontGroup)
    }

    /// 取消和待处理保持页面，成功是否继续业务流程由统一事件处理。
    func purchase(product: PaywallStoreProduct) async throws -> PaywallPurchaseResult {
        guard isActive() else { throw CancellationError() }
        do {
            let result = try await base.purchase(product: product)
            event(.purchaseFinished(productRef: product.productRef, result: result))
            return result
        } catch {
            if !(error is CancellationError) { event(.actionFailed(error.localizedDescription)) }
            throw error
        }
    }

    /// 恢复和购买使用不同事件，避免成功恢复被误当作主动关闭触发挽留。
    func restore() async throws -> PaywallPurchaseResult {
        guard isActive() else { throw CancellationError() }
        do {
            let result = try await base.restore()
            event(.restoreFinished(result))
            return result
        } catch {
            if !(error is CancellationError) { event(.actionFailed(error.localizedDescription)) }
            throw error
        }
    }
}
