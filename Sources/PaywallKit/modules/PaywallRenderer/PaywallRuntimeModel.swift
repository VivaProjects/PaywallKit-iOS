import SwiftUI

@MainActor final class PaywallRuntimeModel: ObservableObject {
    let snapshot: PaywallSnapshot
    let host: PaywallHost
    @Published private(set) var products: [PaywallStoreProduct] = []
    @Published private(set) var selectedRef: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var message: String?
    @Published private(set) var loadFailed = false
    private var impressed = false
    private var transaction: Task<Void, Never>?

    init(snapshot: PaywallSnapshot, host: PaywallHost) {
        self.snapshot = snapshot
        self.host = host
    }

    var selectedProduct: PaywallStoreProduct? { products.first { $0.productRef == selectedRef } }

    /// 每次展示只记录一次曝光，重试仅刷新冻结集合内的商店信息。
    func load() async {
        guard !isLoading, !isPurchasing else { return }
        if !impressed { emit(.impression); impressed = true }
        isLoading = true
        message = nil
        defer { isLoading = false }
        do {
            let fetched = try await host.bridge.products(references: snapshot.productRefs,
                                                         storefrontGroup: snapshot.storefrontGroup)
            try Task.checkCancellation()
            try validateProducts(fetched)
            // 查询结果不能新增、替换冻结的商品集合；可暂时缺少不可售商品。
            products = snapshot.productRefs.compactMap { ref in fetched.first { $0.productRef == ref } }
            let picker = snapshot.document.tree.children?.first { $0.type == .productPicker }
            if !products.contains(where: { $0.productRef == selectedRef }) {
                let recommended = picker?.props.selection == "recommended" ? snapshot.recommendedRef : nil
                selectedRef = products.first(where: { $0.productRef == recommended })?.productRef ?? products.first?.productRef
            }
            loadFailed = false
        } catch is CancellationError {
            return
        } catch {
            products = []
            selectedRef = nil
            loadFailed = true
            message = host.copy.unavailable
            emit(.renderError, ["errorCategory": "product_load"])
        }
    }

    /// 拒绝重复商品、空价格或不属于当前快照的查询结果。
    private func validateProducts(_ fetched: [PaywallStoreProduct]) throws {
        guard !fetched.isEmpty,
              Set(fetched.map(\.productRef)).count == fetched.count,
              Set(fetched.map(\.storeProductID)).count == fetched.count,
              fetched.allSatisfy({ snapshot.productRefs.contains($0.productRef) && !$0.storeProductID.isEmpty
                  && !$0.title.isEmpty && !$0.displayPrice.isEmpty && !$0.disclosure.isEmpty }) else {
            throw PaywallValidationError(path: "$.catalog", reason: "invalid_store_products")
        }
    }

    /// 商品选择只能来自本次商店查询结果，忙碌期间不切换。
    func select(_ product: PaywallStoreProduct, nodeID: String) {
        guard !isPurchasing, !isLoading, products.contains(where: { $0.productRef == product.productRef }) else { return }
        selectedRef = product.productRef
        emit(.selected, ["productRef": product.productRef, "nodeId": nodeID, "selectionSource": "user"])
    }

    /// 同步锁住点击入口，再启动交易，防止快速连点并发下单。
    func purchase() {
        guard !isPurchasing, !isLoading, let product = selectedProduct else { return }
        isPurchasing = true
        message = nil
        emit(.purchaseStarted, ["productRef": product.productRef, "storeProductId": product.storeProductID])
        transaction = Task { [weak self] in
            guard let self else { return }
            await finishTransaction(product: product)
        }
    }

    /// 恢复与购买共用忙碌锁，但不要求商品加载成功。
    func restore() {
        guard !isPurchasing else { return }
        isPurchasing = true
        message = nil
        transaction = Task { [weak self] in
            guard let self else { return }
            await finishTransaction(product: nil)
        }
    }

    /// 购买结果来自商店桥；待批准与用户取消均不能视为权益成功。
    private func finishTransaction(product: PaywallStoreProduct?) async {
        defer { isPurchasing = false; transaction = nil }
        let event: PaywallEvent.Name = product == nil ? .restoreResult : .purchaseResult
        do {
            let result: PaywallPurchaseResult
            if let product { result = try await host.bridge.purchase(product: product) }
            else { result = try await host.bridge.restore() }
            switch result {
            case .succeeded: message = host.copy.succeeded
            case .pending: message = host.copy.pending
            case .noEntitlement: message = host.copy.noEntitlement
            case .cancelled: message = nil
            }
            emit(event, ["result": result.rawValue, "productRef": product?.productRef ?? ""])
        } catch {
            message = host.copy.failed
            emit(event, ["result": "failed", "storeErrorCategory": "bridge_error"])
        }
    }

    /// 强制入口的关闭策略由宿主控制，JSON 无权覆盖。
    func dismiss() {
        guard host.allowsDismiss, !isPurchasing else { return }
        emit(.dismissed, ["reason": "userClose"])
        host.dismiss()
    }

    /// 所有事件附带冻结版本上下文，文档不能指定事件名。
    private func emit(_ name: PaywallEvent.Name, _ fields: [String: String] = [:]) {
        host.track(PaywallEvent(name: name, documentId: snapshot.documentId, revision: snapshot.revision,
                               placement: snapshot.placement, variant: snapshot.document.tracking.variant,
                               rendererVersion: 1, fields: snapshot.assignment.merging(fields) { _, value in value }))
    }
}
