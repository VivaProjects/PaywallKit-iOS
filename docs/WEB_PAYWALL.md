# H5 与宿主接入

## 宿主入口

使用 `PaywallClient` / `PaywallPlacement` 高层入口加载配置、准备页面与管理会话；也可组合 `WebPaywallDocument`、`PaywallHost` 和 `WebPaywallView`。宿主配置服务地址、商品目录及可信 origin，不能从远端 JSON 自行授权来源。

清单见 [Schema](../protocol/web-paywall.schema.json) 和 [示例](../protocol/examples/web-paywall.json)。示例域名与商品值是占位符，必须替换为宿主真实配置。`productRefs` 按页面绑定的实际商店 ID 查询，不按数组位置或点位商品组合替换。

`PaywallPurchaseBridge` 接入宿主商店服务，接口说明见 [原生接入](INTEGRATION.md)。交易完成、权益校验、更新监听和持久化由宿主负责。

## 运行环境与数据

宿主显式配置 `runtimeEnvironment` 为 `test` 或 `production`，默认 `test`，非法值拒绝。配置请求和页面会话使用同一环境，禁止跨环境商品回退。高层入口注入实际 placement，未指定时为空字符串。

环境通过 `WebPaywallEnvironmentConfiguration` 配置。国家使用商店账户的 ISO 3166-1 alpha-3 大写代码，未知为空字符串；设备型号不含唯一标识，版本为面向用户的应用版本。

`sessionContext` 和 `bootstrap` 的 `custom` 平铺包含 `placement`、`runtimeEnvironment`、`language`、`deviceModel`、`country`、`appVersion` 和允许的宿主会话字段。环境字段由 SDK 冻结，custom 不得覆盖价格、披露或页面文案。当前桥协议版本为 2，页面必须匹配此消息结构。

## 页面握手

1. H5 注册 `window.PaywallRuntime.receive`，通过 `PaywallBridge.postMessage` 发送 ready，并声明 productRequest / renderReady 能力。
2. SDK 发送 sessionContext，H5 读取自己的 content.json 和环境绑定。
3. H5 发送 productsRequest，包含当前 sessionID、bridgeVersion、runtimeEnvironment 和 productRefs。
4. SDK 校验请求与发布清单，调用宿主查询商品，再用 bootstrap 注入价格、披露和资格。
5. H5 按精确 ID 渲染，发送 bootstrapped；声明 renderReady 时还需在关键资源与布局就绪后发送 renderReady。

正式页面不得使用预览 USD 演示价格开放购买；缺失有效报价时禁止对应商品购买。标题、按钮、卖点和法律标签由页面维护，购买结果由原生决定。

## 缓存与生命周期

所有 SDK H5 页面统一禁止文字长按选择、复制、剪切及图片和链接的长按系统菜单。普通加载、离线包和预加载页面共用同一创建入口，文档开始加载时即注入限制，并覆盖子框架。按钮点击、正文滚动和购买桥接继续使用原有行为。

宿主可通过 `WebPaywallWebViewCache` 预加载，展示时传入同一 cache、environment 和 custom。环境、商品、资格、点位或 custom 变化后创建新会话，不复用旧 WebView；失效时调用 destroy。配置 `.destroyAfterDismissal` 可在关闭卸载后释放，默认 `.keepAfterDismissal` 保留热页面。

H5 页面与资源使用可信 HTTPS 来源和不可变版本地址。离线包由宿主提供，远端包由发布清单描述并校验；SDK 本身不提供页面或配置发布服务。`WebPaywallResourceCache.shared.clear()` 用于清理可释放缓存，活跃会话资源受租约保护。

上线前在宿主验证加载、断网回退、价格披露、购买成功/取消/待处理、恢复、关闭与会话失效。
