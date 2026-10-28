# PaywallKit iOS SDK

独立 iOS SDK 仓库。根目录即 Swift Package，最低 iOS 16；源码、资源、协议快照、工具与文档均包含在本仓库，不依赖 H5 管理项目或 Flutter SDK。

## 接入

本地接入：在 Xcode 的 Add Local Package 中选择当前目录，添加 `PaywallKit` 产品。

Git 发布后：在 Xcode 的 Add Package Dependencies 中填写本仓库的真实 Git URL，选择已发布的 `X.Y.Z` 版本和 `PaywallKit` 产品。也可在宿主 `Package.swift` 中声明：

```swift
.package(url: "https://github.com/VivaProjects/PaywallKit-iOS.git", exact: "0.5.0")
```

使用版本标签固定依赖；当前版本为 `0.5.0`。

## 维护与发布

```sh
python3 tools/check_package.py
python3 tools/check_cache_loading.py
python3 tools/check_resource_download.py
python3 tools/version.py check
swift package dump-package
xcodebuild -scheme PaywallKit -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/paywall-ios-build CODE_SIGNING_ALLOWED=NO build
```

版本只由本仓库 `VERSION` 管理，变更记录为 `CHANGELOG.md`。升版和发布步骤见 [发布说明](docs/RELEASING.md)。

- [宿主接入](docs/INTEGRATION.md)
- [H5 桥接](docs/WEB_PAYWALL.md)
- [协议契约](docs/PROTOCOL.md)
- [本地包与回退](docs/LOCAL_PAYWALL_FALLBACK.md)

SDK 负责宿主交互、商品查询接口、购买/恢复桥接、会话、缓存及原生回退。业务 H5 文案和页面包由宿主提供，不随 SDK 发布。协议快照位于 `protocol/`，变更时协调其他实现的兼容性，但各自独立发版。

## 诊断日志

SDK 默认独立保存有界滚动日志，控制台默认不打印；开关只控制打印，不影响记录、读取与诊断回调。

```swift
PaywallLogging.printsToConsole = false
let text = await PaywallLogging.read()
let fileURL = try await PaywallLogging.export()
```

需要实时查看时将开关设为 `true`。旧 `mode` 保留兼容：`enabled` 打印，`automatic` / `disabled` 不打印，所有模式均记录。日志只包含配置摘要，不记录请求和响应正文。容量、清理和真机采集方法见 [耗时诊断](docs/LOAD_TIMING.md)。

## 结构化商品价格

支持两端共有的金额、币种、计费周期和适用收费阶段，见 [接入说明](protocol/SUBSCRIPTION_PRICING.md)。旧商品字段保持兼容。

查询入口的启动缓存异步恢复。`cachedPlacement` 只返回已完成完整校验的点位；需要确定目标点位时等待 `resolve`。SDK 自带展示和预加载入口会等待所需快照后再决定页面和容器，其他点位在后台继续恢复。

唯一配置请求可与启动缓存恢复重叠，响应必须等启动版本冻结后才能应用。同一次查询中共用包的点位只归档校验一次，仍分别检查授权并提交索引；索引编码和原子写入在后台串行完成，展示交付仍等待提交成功。该复用不跨查询或启动，完整性、环境与版本规则不变。

同一个展示上下文可一次性交接已验证的本地文档和资源租约；重试重新验证，交接时仍检查当前商品授权和点位禁用。本地仓库初始化同步隔离废弃目录后后台删除，不等待递归清理。

资源交付不等待自动容量清理。清理在后台扫描，删除前重新检查活跃租约及快照索引；`await cache.clear()` 仍等待该次清理完成。归档交接仅复用当前持有资源的验证结果，复制后的目标与跨启动恢复仍完整校验。

本地兜底与历史页面在后台完整校验，校验返回后再次确认当前商品目录、点位禁用与取消状态。普通资源缓存的校验按包调度，同包合并在途工作，不让一个大包阻塞其他包的准备。未提供已验证快照的本地入口异步完成选择后仍可复用已就绪 WebView。

真机加载耗时采集与阶段判读见 [加载耗时诊断](docs/LOAD_TIMING.md)。
