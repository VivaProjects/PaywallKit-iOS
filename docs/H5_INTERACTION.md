# 宿主交互反馈

`WebPaywallView` 与高层 `PaywallScreen` 均接受可选的 `onInteraction: ((PaywallInteraction) -> Void)?`。省略参数时不震动。回调在 MainActor 执行，不添加到价格或资格缓存身份；每次挂载和 SwiftUI 更新时绑定当前闭包，释放时清理。

在现有初始化参数中加入以下回调（宿主文件导入 UIKit）：

```swift
onInteraction: { interaction in
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
}
```

可按 `interaction.action` 区分 `.select` 与 `.purchase` 等动作；`targetID` 仅用于识别页面控件，不是业务成功事件。触觉支持和强度以设备为准，真机验证不能由浏览器或静态检查替代。

协议与生命周期规则见 [INTERACTION.md](../protocol/INTERACTION.md)。
