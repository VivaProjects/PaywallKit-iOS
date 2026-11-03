# 透明全屏覆盖层

查询接口点位行使用 `"displayModeKey":"overlay"`；直接配置使用 `"presentations":{"offer":"overlay"}`。省略展示方式仍为 `fullScreen`。旧 SDK 不保证识别新模式，投放前应先升级宿主 SDK。

使用既有 `paywallHost` 展示 `PaywallScreen`，无需更改商品准备、购买和恢复接口。将 `paywallHost` 挂在覆盖完整窗口内容的宿主根视图（包含 TabView / NavigationStack）上；挂在局部卡片上只能覆盖该局部层级，不能越过另一个系统 sheet 或窗口。需要在系统弹层内展示时，将 host 放在该弹层的根视图。

## 必须遵守的宿主层级

`overlay` 覆盖的是 **paywallHost 所修饰的内容**，并非任意位置调用都能覆盖整个窗口。SDK 对底层触摸和辅助功能的隔离也遵循同一边界。

- 整窗展示：`TabView / NavigationStack` 整体 → 外层 `paywallHost`。
- 局部展示：`TabView` → 某个页面/卡片 → `paywallHost`，无法保证覆盖外层导航栏和 Tab Bar。
- 系统 Sheet / fullScreenCover：在该弹层的完整根内容外安装独立 host；父窗口的 host 无法覆盖更上层的系统弹层，也不能跨窗口。
- UIKit 容器：为子页面新建 `UIHostingController` 时，外层 SwiftUI 的自定义环境不会自动穿过该边界。宿主应显式传递根请求回调/环境，避免子页面重新挂载局部 host。

根宿主持有展示请求；页面只通过回调、绑定或宿主自己的协调器提交入口。SDK 不选择业务根视图，也不重建宿主的导航、Tab 或窗口。后台可能把原有点位改为 overlay，因此应在启用该模式前完成根层级接入。

## 根宿主示例

以下为宿主 `body` 中的结构示意。`request` 是根视图的可选 `@State` 请求（遵循 `Identifiable`，包含 `placement`）；`client`、`prepareInput`、`openLegal`、`canDismiss` 及缓存/资格身份由宿主提供。`OfferEntry` 代表业务页面，通过 `onOpen` 提交点位。`prepareInput` 继续返回真实商店桥的 `PaywallSessionInput`，不在示例中模拟价格或购买。

```swift
TabView {
    NavigationStack {
        OfferEntry(onOpen: { placement in
            request = OfferRequest(placement: placement)
        })
    }
    .tabItem { Label("Home", systemImage: "house") }
}
// 必须修饰整个 TabView，而不是上面的 OfferEntry。
.paywallHost(client: client, item: $request, placement: { $0.placement }) { current in
    PaywallScreen(
        client: client, placement: current.placement,
        validityIdentity: validityIdentity, cacheIdentity: cacheIdentity,
        canDismiss: canDismiss, prepare: prepareInput,
        openLegal: openLegal,
        onEvent: { event in
            switch event {
            case .closed,
                 .purchaseFinished(_, .succeeded),
                 .restoreFinished(.succeeded):
                request = nil
            default:
                break
            }
        }
    )
}
```

`validityIdentity` / `cacheIdentity` 需随宿主的商品、价格、权益、环境及页面上下文变化，不应为了套用示例而写成常量。不同入口共用根宿主时仍需保留各自点位、埋点、购买资格和关闭/挽留策略。

关闭 overlay 时调用系统 `dismiss()` 可能无效或误关闭宿主所在的 Sheet；清空该 host 的请求才是退出契约。需要暂停视频时使用 `onPresented` / `onDismiss`，不要依赖底层页面 `onDisappear`。

## H5 与生命周期

SDK 使用透明 SwiftUI 覆盖层，WKWebView、滚动层和视口均透明；H5 负责遮罩、卡片、关闭按钮和动画。宿主页面保持挂载和可见，因此不会因支付墙出现而自动收到 `onDisappear`。宿主如需暂停视频等任务，使用 `onPresented` / `onDismiss`。覆盖期间底层内容禁止触摸并从辅助功能中隐藏。

H5 的 `html`、`body` 与根节点必须透明。遮罩可使用 `background:rgba(0,0,0,.48)`，装饰图片保留 alpha 通道。遮罩应覆盖整个视口，关闭和购买控件避开 `env(safe-area-inset-*)`。透明仅影响视觉，触摸不会穿透到宿主。SDK 不添加默认遮罩，也不因点击透明区域自动关闭。

关闭按钮和可关闭遮罩发送既有 `close` 桥动作，继续受 `canDismiss` 与交易门禁限制。宿主收到 `.closed` / 购买成功等事件后，按原接入流程清空 `paywallHost` 的 item；不要使用 SwiftUI 的系统 `dismiss()` 关闭 overlay，以免关闭宿主所在的系统弹层。请求取消、宿主卸载和退场统一释放会话，`onDismiss` 每次请求最多一次。

加载和错误沿用现有 SDK 状态视图；H5 首屏就绪后显示页面。需要避免可见加载阶段时使用既有 `waitsForReady` 或预加载接口。自定义加载处理器仍由宿主提供可操作的状态反馈。

价格及披露必须来自商店，资格由宿主确认，文案来自页面 `content.json`。不增加 bootstrap 字段。页面背景不透明时仍会遮住宿主，需要更新 H5 页面包；仅更改后台模式不会使现有不透明页面自动透明。

回归测试：`python3 tools/check_overlay_configuration.py` 使用真实 Foundation 解析器验证完整配置、商品绑定、预加载及非法值；`Tests/PaywallKitTests/PaywallOverlayTests.swift` 覆盖模式解析、旧值、非法值与 WebView/视口透明度。真实展示还需在宿主设备检查状态栏和安全区、背景隔离、关闭、购买/恢复、法律页、预加载接管和卸载。
