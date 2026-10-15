# PaywallKit iOS SDK

独立 iOS SDK 仓库。根目录即 Swift Package，最低 iOS 16；源码、资源、协议快照、工具与文档均包含在本仓库，不依赖 H5 管理项目或 Flutter SDK。

## 接入

本地接入：在 Xcode 的 Add Local Package 中选择当前目录，添加 `PaywallKit` 产品。

Git 发布后：在 Xcode 的 Add Package Dependencies 中填写本仓库的真实 Git URL，选择已发布的 `X.Y.Z` 版本和 `PaywallKit` 产品。也可在宿主 `Package.swift` 中声明：

```swift
.package(url: "<IOS_SDK_GIT_URL>", exact: "0.1.0")
```

示例 URL 需要替换，版本标签必须已经存在；当前版本登记不表示远端已发布。

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
