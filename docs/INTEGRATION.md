# SDK 接入

复杂页面的 H5 WebView 接入见 [H5 支付墙接入](WEB_PAYWALL.md)；本页以下内容仍是语义 JSON 原生渲染器的接入方式。

两个包共享 `protocol/examples/onboarding.json`，使用相同 catalogKey 与 productRef 语义。宿主可以用不同 StoreKit/Google Play 商品 ID 实现同一 productRef。SDK 不内置订阅商店 SDK，也不替换现有购买服务。

## iOS SwiftUI

在 Xcode 添加独立 iOS 仓库根目录为本地 Swift Package，引入 `PaywallKit`。最低 iOS 16。以下为接入结构，`subscriptionBridge`、法律路由和图片名由宿主提供。

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

## Flutter/GetX

宿主 pubspec：

```yaml
dependencies:
  native_paywall:
    path: ../flutter
```

```dart
import 'package:native_paywall/native_paywall.dart';
import 'package:get/get.dart';

final catalogs = {
  'default': PaywallCatalog(
    productRefs: ['annual', 'monthly'], recommendedRef: 'annual'),
};
final snapshot = await PaywallConfigurationService().loadBundled(
  placement: 'onboarding_complete', locale: 'zh-Hans-CN',
  storefrontGroup: 'default', catalogs: catalogs,
  assetIDs: {'movement_hero'},
);

// 每次打开使用不同 sessionTag；不要复用仍存在的路由实例。
final sessionTag = 'paywall-${DateTime.now().microsecondsSinceEpoch}';
Get.to(
  () => PaywallRendererView(
    sessionTag: sessionTag,
    assetBuilder: (id) => id == 'movement_hero'
      ? Image.asset('assets/paywall_hero.png', fit: BoxFit.contain) : null,
  ),
  binding: PaywallRendererBinding(
    sessionTag: sessionTag,
    createController: () => PaywallRuntimeController(
      snapshot: snapshot, bridge: subscriptionBridge,
      allowsDismiss: true, onDismiss: () => Get.back<void>(),
      openLegal: (route) { /* 宿主固定法律路由 */ },
      track: (event) { /* 宿主事件转发 */ },
    ),
  ),
);
```

宿主 View 需要正常导入 `package:flutter/material.dart`。也可以将 `PaywallRendererBinding` 绑定到集中定义的 GetPage。不要在 View、build 或 Controller 中注册依赖。宿主的配置/购买/缓存服务由其 Binding 提供，Controller 仅接收构造注入。

独立服务端接入，`jsonString` 是宿主网络层取得的 UTF-8 JSON 字符串：

```dart
final snapshot = await PaywallConfigurationService().decodeDocument(
  jsonString,
  placement: 'onboarding_complete', locale: 'zh-Hans-CN',
  storefrontGroup: 'default', catalogs: catalogs,
  assetIDs: {'movement_hero'},
);
```

将返回的 Snapshot 注入上面的 route Binding。宿主负责下载、来源验证、缓存和回退；等待后检查生命周期，避免页面销毁后导航。解码失败可调用 `loadBundled`，再失败则使用宿主固定原生页面。

`PaywallPurchaseBridge` 的三个方法对应 iOS。Google Play 适配器必须使用真实 ProductDetails 和已确认资格的 offer；productRef 与 storeProductId 都由宿主映射，不把远端 JSON 直接转成交易参数。Controller 销毁后不再回写 Rx，已发起的交易与权益处理仍由宿主商店层完成。

## 原生资源与无障碍

assetIDs 是允许引用的稳定资源 ID；assetBuilder/image 回调必须从宿主静态映射表解析，不能把 assetId 当作任意 URL 下载。缺失非关键图片显示占位与替代文本。加载/错误/法律文案用 PaywallRuntimeCopy 本地化；文本组件随系统字号缩放。颜色不能单独表达选择态，组件同时使用勾选图标与语义选中标志。

两端固定底栏都限制最大高度并允许长披露文案滚动，正文独立可滚动。没有自定义动画，因此不引入需要远端解释的 Reduce Motion 动效。最终仍需真机检查 VoiceOver/TalkBack、窄屏、极大字号和安全区。

## 分发与事件边界

本项目不提供服务端。JSON 分发、灰度选版、发布审批和监控由独立服务端及宿主现有基础设施负责。编辑器导出普通文档，SDK 的 `decodeDocument` 不强制 Manifest、URL 路径或签名算法。

SDK 通过 `track` 回调输出固定事件及文档版本，宿主转发现有分析系统；没有必须调用的 `/api/events`。

源码中已有的 `PaywallRemoteProvider` 保留为可选历史客户端适配器，依赖原先的签名 Manifest 格式；本次接入不使用它，也不要求后续服务端兼容它。主流程使用上述 `decodeDocument`。


## 测试环境诊断日志

SDK 默认独立保存日志，`PaywallLogging.printsToConsole` 默认为 `false`，只控制控制台打印。关闭打印仍可调用 `read()` / `export()`，`clear()` 清理现存日志。旧模式 `enabled` 打印，`automatic` / `disabled` 不打印，均保留记录和更新诊断回调。不改变业务环境，也不记录原始配置请求和响应正文。容量和真机采集方法见 [耗时诊断](LOAD_TIMING.md)。

- `preload.*` / `prepared_page.*`：准备、复用、就绪、接管、取消、超时及失败。
- `cache.*`：WebView 缓存命中、身份不匹配、挂载接管、保留、释放和清理。
- `resource.*`：磁盘命中、失效、共享下载、下载等待/完成、租约释放及容量/手动淘汰；`page.load` 标明 bundled、disk 或 remote 来源。
- `session.*` / `navigation.*` / `render.*` / `bridge.*`：宿主挂载、导航、握手、首屏回执、消息投递和失败原因。
- `products.*` / `action.*`：商品查询计数及购买/恢复开始、结果或失败。
- iOS `webview.layout` / `webview.deinit`：窗口挂载、实际视口变化及对象释放。`cache.clear` 表示清理流程执行，只有 `webview.deinit` 表示 WebView 对象已释放；Flutter 插件对象由插件/路由持有，`session.stop` 不表示已收到原生对象释放回执。

会话日志包含 `session`、`placement`、`document`、`elapsedMs`，资源日志使用环境隔离后的资源键关联。只记录标识、状态、计数和错误码/类型，不输出原始桥消息、`custom`、价格、交易凭据或完整 URL。iOS 配置网络与本地回退日志只在请求明确携带 `runtimeEnvironment=test` 时输出；自定义请求未提供环境时不推断环境。高层预加载尚未取得会话输入时没有会话环境，因此以配置请求日志定位这一阶段。

### 内嵌展示与免费试用资格

`PaywallScreen` 和 `WebPaywallView` 支持 `isPresented`，默认 `true`。设为 `false` 时可以准备网页并接收 `renderReady`，但不会通知正式可见或接受购买、恢复、关闭、法律链接动作。宿主在内容真正可见时设为 `true`，并自行在就绪且可见后记录曝光。`PaywallScreen.localPackages` 可选地指定当前入口的独立离线包策略，不改变其它点位。

`PaywallStoreProduct.isEligibleForFreeTrial` 是可选布尔字段，iOS 与 Flutter bootstrap 均透传；未提供时 H5 应按无试用承诺展示。iOS 的 `PaywallStoreKitProductMapper` 仅在账户符合 introductory offer 资格且支付方式为 `freeTrial` 时返回 `true`。Flutter 接入方必须从商店资格适配层提供此值。页面按钮文案由 H5 维护，实际试用期限、金额及条件仍使用宿主的商店披露，不解析价格字符串猜测资格；协议版本保持 2。

纯展示会话可由 iOS 宿主的 `PaywallPurchaseBridge.requiresStoreProducts` 显式返回 `false`（默认 `true`），允许空商品 bootstrap 并拒绝交易动作。此权限只由原生桥决定，H5 的 custom 不得授予交易权限；现有付费会话行为不变。

### 空商品展示与交易权限（0.1.5）

`requiresStoreProducts` 只控制页面是否必须取得商品才能完成 bootstrap。`allowsStoreActions` 独立控制购买与恢复，默认沿用 `requiresStoreProducts`，保持旧纯展示桥禁用交易。允许空商品展示但仍提供购买的宿主，应设置 `requiresStoreProducts = false`、`allowsStoreActions = true`；购买仍必须命中本次商店返回的商品。高层会话包装桥透传两项权限，被拒绝的交易动作回传 failed，避免网页停留在等待态。桥消息格式不变。

### iOS 曝光商品口径

`PaywallSessionEvent.ready(productRefs:)` 返回本次 H5 `productsRequest` 中通过校验的商品 ID，保留请求顺序，包括商店未返回的商品；不返回文档完整绑定或商店可售结果。预加载和热页复用保留同一 WebView 会话的请求列表。旧 H5 未声明 `productRequest` 能力时返回空数组，不用发布清单补齐。底层接入可使用 `WebPaywallView.onReadyProducts` 获取同一列表，原 `onReady` 回调保持兼容。此改动不改变 H5/Flutter 的桥消息协议。


## 延迟商品加载（0.2.2）

H5 同时声明 `productRequest`、`renderReady`、`deferredProducts` 时，iOS 在合法 `productsRequest` 后先发送空商品 `bootstrap`，商品查询成功后发送 `productsUpdated`。页面必须在真实商品与披露到达前禁用购买，不得填充演示价格。延迟模式商品查询上限为 12 秒，失败沿用商品不可用处理。未声明该能力的旧页继续等待商品后初始化；Flutter 1.1.0 起也支持此可选能力，页面仍须兼容旧宿主带商品的常规 bootstrap。

## 0.3.0 设备参数接入

升级依赖到 `0.3.0`。SDK 向 H5 的 `custom` 平铺注入 `os`（`iOS` / `Android`）与 `isPad`（布尔值），POST 查询在 `conditions` 中传同名字段；GET 使用字符串查询参数。设备参数变化后需新建会话。

SwiftPM：`.package(url: "https://github.com/VivaProjects/PaywallKit-iOS.git", exact: "0.3.0")`。查询式入口自动采集 iOS 与 iPad 状态；会话配置可通过 `WebPaywallEnvironmentConfiguration(os: "iOS", isPad: true)` 显式覆盖。


## 商店国家缓存兜底

国家查询成功后保存最近一次有效的 ISO alpha-3 大写国家码；后续查询返回空值时读取缓存，无缓存才传空字符串。缓存按应用及 `runtimeEnvironment` 隔离，跨启动保留，不设置过期时间。新的成功结果覆盖旧值，失败不清空缓存。

仅沿用既有单次商店查询，不新增网络请求、重试、延时窗口或同步落盘等待。缓存不能缩短商店调用本身的耗时；账户切换后若查询失败，可能暂时沿用旧国家。真实商品价格与资格仍由商店提供，不从缓存国家推断。
