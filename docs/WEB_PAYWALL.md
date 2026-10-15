# H5 桥接与宿主接入

SDK 只提供通用展示、桥接、配置校验与商店交互接口。H5 页面、投放配置与服务地址由宿主业务提供，SDK 不内置业务页面或点位规则。

## 页面清单与商品

清单格式见 [web-paywall.schema.json](../protocol/web-paywall.schema.json)，示例见 [web-paywall.json](../protocol/examples/web-paywall.json)。宿主先验证配置来源，再用可信 origin 白名单及预注册的 `PaywallCatalog` 构造 `WebPaywallDocument`。白名单不能由下发 JSON 自行授权。`productRefs` 填写真实商店商品 ID，必须属于宿主注册目录；原生按照关联页面清单查询，不沿用原点位的商品组合。

正式页面使用 HTTPS 和不可变版本 URL。iOS Debug 可显式允许指定 HTTP origin；Release 和 Flutter 不接受 HTTP 页面清单。SDK 不提供生产配置服务、页面上传或 ZIP 离线下载；离线页面由宿主资源包维护。

## 宿主入口

- iOS：可使用 `PaywallClient` / `PaywallPlacement` 的高层入口读取配置、准备页面并管理会话；也可直接组合 `WebPaywallDocument`、`PaywallHost`、`WebPaywallView`。配置格式由 `WebPaywallConfiguration` 校验，服务地址与业务条件由宿主提供。
- Flutter：宿主解析单页 `WebPaywallDocument` 后创建 `WebPaywallController`，通过 `WebPaywallBinding` 注入独立路由会话。Flutter 当前没有与 iOS `PaywallClient` 对等的高层投放配置客户端；宿主负责投放 JSON 的获取和点位解析。
- 两端的 `PaywallPurchaseBridge` 均由宿主接入真实商店服务；接口实现方式见 [原生接入文档](INTEGRATION.md)。交易完成、权益校验和持久化由宿主负责。

## H5 数据边界

H5 自行加载同版本的 `content.json` 并校验文案和展示绑定；原生不注入标题、按钮、卖点或法律标签。浏览器独立预览可使用 USD 演示报价，正式页面必须等待有效商店报价及披露，缺少绑定商品时禁止购买，也不能借用其他商品。

H5 通过 `PaywallBridge.postMessage(JSON.stringify({type,...}))` 发送动作；原生调用 `window.PaywallRuntime.receive(...)`。`bootstrap` 仅包含 `type`、`bridgeVersion`、`sessionID`、受限的会话级 `custom` 和 `products`。商品以真实 ID 作为 `productRef` 匹配，展示价格、披露和宿主确认的资格；购买与恢复结果使用状态码，提示文案由 H5 维护。

`custom` 平铺包含 `placement`、`language`、`deviceModel`、`country`、`appVersion`、`runtimeEnvironment`。国家必须来自商店账户，使用 ISO alpha-3 大写值，未知传空字符串；设备型号不能是设备唯一标识。iOS 可通过 `WebPaywallEnvironmentConfiguration` 单独覆盖字段，未配置字段使用 SDK 当前默认值；Flutter 由宿主提供环境对象。`custom` 不得包含或覆盖商店价格、披露或页面文案。环境、商品资格或 custom 改变后创建新会话，不复用旧 WebView 会话。

## 加载与首屏就绪

双端先准备环境并加载 H5，收到页面的商品请求且通过发布清单校验后查询宿主商品。商品返回后只注入一次 `bootstrap`；H5 等待自己的文案资源完成校验后渲染。重复 `ready` 不会再次请求商品或重置购买状态。12 秒总超时从会话启动计时，覆盖主文档、脚本、文案资源、商品、关键图片和渲染回执。iOS 宿主可以选择缓存 WebView，同时每次重新创建系统弹窗；销毁、超时或回退会结束会话，晚到结果不再更新页面。宿主已发起的商店交易仍由宿主负责完成。

bridgeVersion 升为 2，因为页面文案已移出原生注入协议；新宿主拒绝旧版清单，旧版宿主也不能接入新版清单。首屏回执仍按以下流程处理：

页面商品声明采用以下顺序（桥版本仍为 2）：

1. H5 注册接收器后发送 `ready`，声明 `capabilities: ['renderReady', 'productRequest']`。
2. 原生发送 `sessionContext`，包含 `bridgeVersion`、`sessionID`、`custom`（包含平铺的全部环境字段及业务字段），此时尚未查询商品。
3. H5 加载、校验自身 `content.json`，按明确的 `runtimeEnvironment` 选择绑定，发送 `productsRequest`：`{type:'productsRequest', bridgeVersion:2, sessionID, runtimeEnvironment:'test', productRefs:[...]}`。冷启动变体由宿主 custom 指定，H5 只根据自身绑定声明展示所需商品。
4. 原生确认会话、环境、非空且不重复的商品列表，以及请求列表属于当前页面发布清单后，调用宿主商店查询。重复请求不重新查询，清单外商品或跨环境请求使会话失败。
5. 原生用 `bootstrap` 返回请求范围内查到的商品价格、披露和资格；不注入商品标题。H5 按精确 ID 匹配，页面按自身规则处理缺失商品，未获得有效报价的商品不能购买。
6. H5 更新 DOM 后发送 `bootstrapped`，原样返回 `sessionID`；共享 `render-ready.mjs` 等待关键资源、字体和两次 animation frame 后发送 `renderReady`，宿主再移除遮罩。

旧 H5 未声明 `productRequest` 时，SDK 在 `ready` 后按发布清单查询；新 H5 仍可接收旧宿主直接发送的 `bootstrap`。会话环境、custom、页面或绑定变化必须创建新会话。浏览器预览模拟同一环境→商品请求→注入顺序，演示价格不进入原生交易。

未声明 `renderReady` 能力时，宿主继续以 `bootstrapped` 完成加载；声明后须等待 `renderReady`。重试或更换文档须创建新的展示身份；单次展示期间不重新导航或替换清单。

H5 提供 `paywall-bridge-ready`、`paywall-bootstrap-ack`、`paywall-render-ready` 三个 Performance mark，供浏览器分析使用。共享模块在打包时复制进版本目录并重写为相对导入；iOS Demo 则合并为离线经典脚本。

## HTTP 缓存

iOS 远端入口使用 `.useProtocolCachePolicy`，Flutter 沿用 WebView 默认 HTTP 缓存。部署时为不可变版本目录内的 HTML、CSS、JS、图片配置 `Cache-Control: public, max-age=31536000, immutable`；清单发现接口使用短缓存或重新验证。发布必须使用新的版本 URL，不能覆盖已有目录。服务器响应头未配置前，不应假定每次打开都能命中缓存。

iOS SDK 的 `WebPaywallWebViewCache.preload` 可在展示前加载页面与商品并尝试完成桥接；屏幕外的 WebView 若暂停首屏回执，正式展示时才启动 12 秒超时并继续等待。宿主按入口持有缓存，可在进入引导流程、打开设置入口前等场景自行选择预加载时机。`WebPaywallWebViewCache(retentionPolicy: .keepAfterDismissal)` 默认保留热页面；`.destroyAfterDismissal` 在 SwiftUI 卸载页面时销毁；`destroy()` 可主动取消尚未展示的预加载，已挂载页面会在卸载时销毁。不要在页面仍展示时替换缓存实例。首次商品查询尚未完成时入口显示准备状态。浏览器缓存不等于经过校验的完整离线包。

iOS 的每个 `WebPaywallWebViewCache` 实例只保留一个已加载的 WKWebView 和它的桥接会话，可让 `fullScreenCover` 每次重新创建并保持系统动画。缓存键包含页面 URL、revision、商品引用、店面、外部环境配置和 `custom`；不匹配或页面故障时会重新加载。预加载与正式展示必须传入同一份环境配置和 `custom`。复用期间页面上的价格、环境信息和 `custom` 仍是首次注入值，因此商店国家、价格、资格或应用语言变化时应调用 `destroy()` 并用新商品重新预加载。宿主自行选择各点位的预加载和关闭后保留策略，刷新商品时销毁旧缓存。

Flutter/GetX 可按入口持有 `WebPaywallPreloader(() => WebPaywallController(...))`。场景到达时调用 `preload()`；路由的 `WebPaywallBinding.createController` 使用 `preloader.take() ?? WebPaywallController(...)` 接管一次预加载会话。路由关闭时 GetX 调用 `onClose()` 阻断桥接并释放路由持有的 WebView；场景取消、商品或环境配置变化且尚未展示时调用 `preloader.destroy()`。预加载器会在 `preload()` 和 `take()` 时重新读取 `custom`，变化后销毁旧会话。Flutter 插件没有同步销毁原生 WebView 的公开方法，实际原生资源释放由 `WebViewWidget` 卸载和平台插件管理，宿主不要继续持有已关闭的 controller。每个入口使用独立句柄，且只有文档、店面、商品资格、环境配置和 `custom` 未变化时才复用。

```swift
// iOS：每个入口单独持有，按业务时机调用 preload。
let environment = WebPaywallEnvironmentConfiguration(
    language: appLanguageTag,
    appVersion: appVersion
)
let custom: [String: WebPaywallJSONValue] = ["entry": "onboarding", "context": ["screen": "intro", "step": 2]]
let cache = WebPaywallWebViewCache(retentionPolicy: .destroyAfterDismissal)
cache.preload(document: document, storefrontGroup: storefrontGroup,
              host: host, environment: environment, custom: custom)
// 展示时 WebPaywallView(..., environment: environment, custom: custom, webViewCache: cache, ...)
// 展示时传入同一 cache；入口失效或商品变化时调用 cache.destroy()。
```

```dart
// Flutter：factory 同时供预加载和没有热页时的普通打开使用。
WebPaywallController makeController() => WebPaywallController(
  document: document, storefrontGroup: storefrontGroup, bridge: bridge,
  environment: WebPaywallEnvironment(
    language: appLanguageTag, deviceModel: deviceModel,
    country: storeCountryAlpha3, appVersion: appVersion,
  ),
  custom: {'entry': 'onboarding', 'context': {'screen': 'intro', 'step': 2}},
  allowsDismiss: true, dismiss: () => Get.back<void>(),
  openLegal: openLegal,
);
final preloader = WebPaywallPreloader(makeController);
preloader.preload(); // 宿主选择的场景，例如进入购买流程之前。
Get.to(
  () => WebPaywallView(sessionTag: sessionTag, nativeFallback: nativeFallback),
  binding: WebPaywallBinding(
    sessionTag: sessionTag,
    createController: () => preloader.take() ?? makeController(),
  ),
);
// 未展示的预加载失效时：preloader.destroy();
```

Android JavaScript channel 可被页面中的脚本调用，所以静态资源必须放在宿主控制的专用来源上，保持 CSP 限制和不可变版本路径；生产站点还应通过响应头设置 `frame-ancestors 'none'`。上线前需在真实 iOS/Android 宿主中验证加载、断网回退、合法披露、购买取消/待处理/成功、恢复、系统返回和商店审核要求。此仓库的静态检查与浏览器预览不等同于真机购买验证。

- H5 只负责页面展示、读取注入商品数据和发送桥接动作，不决定点位路由、商品查询、优惠资格、购买、恢复或购买结果；这些业务逻辑由原生负责。页面内部的选中态、动画和布局由 H5 实现。
- 点位可以自由关联 H5。原生必须按关联 H5 的 `page.json` / 发布清单中绑定的 `productRefs` 查询并注入对应商店 ID，H5 按 ID 精确读取，不能按数组位置、原点位商品组合或 A/B、X/Y 业务规则替换。`content.json` 中展示绑定须与清单一致；缺少绑定商品时正式页不得借用其他商品或演示价格开放购买。



## 运行环境

桥接版本仍为 2。`bootstrap.custom.runtimeEnvironment` 取 `test` / `production`，缺省为 `test`；H5 必须拒绝显式非法值。环境由应用配置选择，与商店 Sandbox、编译模式及地区无关。商品清单必须先在配置服务按环境解析，原生查询实际商品 ID 后才注入；H5 不负责查询或跨环境回退。

iOS 使用 `WebPaywallRuntimeEnvironment`：给 `PaywallRequestParameters(runtimeEnvironment: .production)` 与 `PaywallSessionInput(..., environment: .init(runtimeEnvironment: .production))` 传同一值。参数会进入 GET 请求和配置缓存 URL，WebView 缓存键也包含环境。切换环境时创建新 Client 和新会话，不复用旧 Client 的已冻结配置。

Flutter 使用 `WebPaywallEnvironment(..., runtimeEnvironment: WebPaywallRuntimeEnvironment.production)`；`toPayload()` 同时可用于宿主配置请求参数。宿主缓存配置时必须包含该参数，并先解析同环境清单再创建 Controller；SDK 预加载复用比较完整环境与页面绑定。未指定时两端均默认为测试环境。


`bootstrap.custom.placement` 为当前会话点位名称，H5 读取 `PaywallRuntime.custom.placement`。iOS PaywallClient 高层展示及预加载在解析点位后自动填入，覆盖输入中的点位；直接使用底层 WebPaywallView 或 Flutter 时，宿主通过环境对象的 `placement` 参数传实际入口。缺省和旧宿主未传时为 `""`，不从 documentId 或 storefrontGroup 推断。共享同页的不同入口保留各自名称，并参与 WebView 缓存比较。整份配置请求不自动添加 placement；管理预览按点位模式注入选中点位，直接选页模式为空。

## Persistent page resources

Normal presentation and preloading automatically use `WebPaywallResourceCache` on iOS and Flutter. A remote page may publish a sibling `package.json` with `formatVersion: 1`, `runtimeEnvironment`, the exact delivery `document`, `entry: "offline.html"`, and `files: [{path,size,sha256}]`. The offline entry must use local classic scripts and contain its own page-authored content; it must not require ESM or network fetches for `content.json`. Existing manifests need no extra fields. Old pages without a package continue loading remotely.

The cache keys the complete remote document and environment, validates every file on disk, merges concurrent requests and atomically installs complete packages. It downloads at most two pages concurrently, with a six-second deadline per started package; the existing presentation deadline still applies. Limits: 256,000-byte index, 1,000 files, 100 MiB per package, 300 MiB default disk capacity. Requests cannot redirect. No historical-version or cross-environment fallback is permitted; package failure falls back to the current remote document only. Pinning protects resources while a session is using them. Only unpinned packages are evicted by last use.

Resources live in private persistent storage excluded from backups. Flutter now includes a minimal iOS/Android directory plugin; run dependency resolution and reintegrate native dependencies when updating the SDK. The plugin does not handle content, pricing or transactions. WebViews and store data are recreated each launch. A host-side change to product bindings requires an exactly matching package; do not reuse a page's original bundle after narrowing its bindings.

To clear idle files call `await WebPaywallResourceCache.shared.clear()` on either platform. Ordinary sessions own leases automatically. Advanced callers using `prepare` retain the Swift `WebPaywallResourceLease` until finished, or call Flutter `lease.release()`. Flutter controllers accept an optional `resourceCache` for injection; custom directory/download parameters are intended for tests. Publish immutable per-page URLs and install resources before switching delivery configuration.

## H5 环境字段统一注入 custom

`sessionContext` 和 `bootstrap` 不再发送顶层 `environment`。`custom` 平铺包含 `placement`、`runtimeEnvironment`、`language`、`deviceModel`、`country`、`appVersion`，并保留宿主传入的业务字段（例如 `questionnaireResult`、`coldStartVariant`）。同名冲突时以 SDK 冻结的环境值为准。H5 从 `message.custom` / `PaywallRuntime.custom` 读取；宿主 SDK 的 environment 配置入口及缓存身份不变。

这是桥消息结构变更，SDK 与页面包必须配套发布；已发布的旧页面包需要重新打包并递增 revision，不能覆盖原有不可变包。
