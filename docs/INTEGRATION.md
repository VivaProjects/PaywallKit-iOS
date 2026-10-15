# SDK 接入

复杂页面的 H5 WebView 接入见 [H5 支付墙接入](WEB_PAYWALL.md)；本页以下内容仍是语义 JSON 原生渲染器的接入方式。

SDK 内置 `protocol/examples/onboarding.json`，使用相同 catalogKey 与 productRef 语义。宿主可以用不同 StoreKit 商品 ID 实现同一 productRef。SDK 不内置订阅商店 SDK，也不替换现有购买服务。

## iOS SwiftUI

在 Xcode 添加本仓库的 Git URL 或本地仓库根目录，引入 `PaywallKit`。最低 iOS 16。以下为接入结构，`subscriptionBridge`、法律路由和图片名由宿主提供。

```swift
import PaywallKit
import SwiftUI

// 这些值由宿主配置与持久化层提供。
let catalogs = ["default": PaywallCatalog(
    productRefs: ["annual", "monthly"], recommendedRef: "annual")]

let snapshot = try PaywallSnapshotFactory().loadBundled(
    placement: "onboarding_complete", locale: "zh-Hans-CN",
    storefrontGroup: "default", catalogs: catalogs,
    assetIDs: ["movement_hero"])

// 在 MainActor 上创建。
let host = PaywallHost(
    bridge: subscriptionBridge,
    allowsDismiss: true,
    image: { id in id == "movement_hero" ? Image("PaywallHero") : nil },
    openLegal: { route in /* 映射 route 到现有隐私/条款页面 */ },
    dismiss: { /* 现有关闭行为 */ },
    track: { event in /* 固定事件名 + documentId/revision + fields */ })

PaywallRendererView(snapshot: snapshot, host: host)
```

加载本地文档也可能失败。用 `PaywallEntryView(host:load:reportFallback:nativeFallback:)` 包装，`nativeFallback` 返回现有固定原生支付墙。回调里的配置错误仅用于诊断，不应展示原始内部信息给用户。

独立服务端接入：宿主使用现有网络层取得 UTF-8 JSON，再调用统一解码入口。这里的 `jsonData` 是宿主取得的 `Data`，不要求特定 URL、响应信封或鉴权方案。

```swift
let snapshot = try PaywallSnapshotFactory().decodeDocument(
    jsonData,
    placement: "onboarding_complete", locale: "zh-Hans-CN",
    storefrontGroup: "default", catalogs: catalogs,
    assetIDs: ["movement_hero"])
```

宿主负责响应状态、下载大小、超时、来源验证和缓存策略；SDK 负责固定协议、组件能力和业务规则校验。每次进入页面生成独立 Snapshot，页面打开期间不要替换快照。解码失败时，尝试宿主最近可用配置或 `loadBundled`；仍失败则展示固定原生支付墙。

`PaywallPurchaseBridge` 在 MainActor 上实现：

- `products(references:storefrontGroup:)`：只查询宿主映射表内的商品，返回 `PaywallStoreProduct`。价格使用商店的本地化 `displayPrice`；`disclosure` 由宿主根据商店订阅周期、资格和披露规范生成。不得由远端文案生成试用承诺。
- `purchase(product:)`：验证 productRef/storeProductID 映射后调用现有 StoreKit 流程；只在凭据/权益验证成功后返回 `.succeeded`。`.pending` 和 `.cancelled` 必须单独返回。宿主负责交易完成、监听更新与持久化权益。
- `restore()`：调用现有恢复流程，无权益时返回 `.noEntitlement`。

页面在商品加载失败时禁用购买，保留重试、恢复和法律入口。购买与恢复共享忙碌锁；购买结果仍由宿主负责完成业务导航。
