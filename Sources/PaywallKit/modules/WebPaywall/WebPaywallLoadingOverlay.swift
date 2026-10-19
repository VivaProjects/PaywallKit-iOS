import SwiftUI

/// 只在可见加载阶段发布状态；宿主接管后 SDK 不绘制加载 UI。
struct WebPaywallLoadingOverlay: View {
    @Environment(\.paywallLoadingHandler) private var handler
    @State private var id = UUID()
    @State private var active = false
    let label: String
    let closeLabel: String
    var canDismiss = true
    var onClose: (() -> Void)?

    var body: some View {
        Group {
            if handler == nil {
                PaywallDefaultLoadingOverlay(label: label, closeLabel: closeLabel,
                                             canDismiss: canDismiss, onClose: onClose)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            }
        }
        .onAppear { active = true; report() }
        .onChange(of: canDismiss) { _ in report() }
        .onDisappear {
            active = false
            handler?(PaywallLoadingState(id: id, isLoading: false, cancel: nil))
        }
    }

    /// 取消只作用于仍可见的本次展示，晚到回调不得关闭下一次付费墙。
    private func report() {
        guard active else { return }
        // 显式分支为可选 MainActor 闭包提供类型上下文，避免三元表达式触发编译器诊断失败。
        let cancel: (@MainActor () -> Void)?
        if canDismiss, let onClose {
            cancel = { @MainActor in
                guard active, canDismiss else { return }
                onClose()
            }
        } else {
            cancel = nil
        }
        handler?(PaywallLoadingState(id: id, isLoading: true, cancel: cancel))
    }
}
