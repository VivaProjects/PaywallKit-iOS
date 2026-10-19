import SwiftUI

/// 配置、商品和网页准备共用轻遮罩，原生菊花不显示可见文案。
struct PaywallDefaultLoadingOverlay: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let label: String
    let closeLabel: String
    var canDismiss = true
    var onClose: (() -> Void)?

    var body: some View {
        ZStack {
            Group {
                if reduceTransparency {
                    Color(uiColor: .systemBackground)
                } else {
                    Color.black.opacity(0.12)
                }
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { }
            .accessibilityHidden(true)
            ProgressView()
                .controlSize(.large)
                .tint(.primary)
                .accessibilityLabel(label)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if let onClose {
                closeButton(action: onClose)
                    .disabled(!canDismiss)
                    .padding(16)
            }
        }
    }

    /// 加载期间保留取消入口，新系统采用原生玻璃按钮。
    @ViewBuilder
    private func closeButton(action: @escaping () -> Void) -> some View {
        if #available(iOS 26.0, *) {
            Button(action: action) {
                Image(systemName: "xmark").frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .accessibilityLabel(closeLabel)
        } else {
            Button(action: action) {
                Image(systemName: "xmark").frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel(closeLabel)
        }
    }
}
