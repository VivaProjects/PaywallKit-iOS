# PaywallKit iOS SDK

独立 iOS SDK 仓库。根目录即 Swift Package，最低 iOS 16；源码、资源、协议快照、工具与文档均包含在本仓库，不依赖 H5 管理项目或 Flutter SDK。

## 接入

本地接入：在 Xcode 的 Add Local Package 中选择当前目录，添加 `PaywallKit` 产品。

Git 发布后：在 Xcode 的 Add Package Dependencies 中填写本仓库的真实 Git URL，选择已发布的 `X.Y.Z` 版本和 `PaywallKit` 产品。也可在宿主 `Package.swift` 中声明：

```swift
.package(url: "https://github.com/VivaProjects/PaywallKit-iOS.git", exact: "0.3.0")
```

使用版本标签固定依赖；本次设备参数版本为 `0.3.0`。

## 维护与发布

```sh
python3 tools/check_package.py
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

在创建 `PaywallClient` 前配置 SDK 全局日志模式：

```swift
PaywallLogging.mode = .enabled   // test、production 均输出
// PaywallLogging.mode = .disabled  // 全部关闭
// PaywallLogging.mode = .automatic // 默认：仅 test 输出
```

开关线程安全，可在运行中调整，只影响之后的日志输出；不会改变请求环境、商品绑定或缓存身份。生命周期、查询和配置请求日志统一受控，前缀保留实际环境，例如 `[PaywallKit][production]`。在 Xcode 控制台筛选 `PaywallKit`，或在 macOS Console 中选择连接设备并按 subsystem `PaywallKit` 筛选。

开启时包含配置请求和响应正文（不含请求头），用于排查的版本可开启，诊断结束后可切回 `.automatic` 或 `.disabled`。
