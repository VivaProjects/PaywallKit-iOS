# PaywallKit-iOS

iOS 支付墙 SDK：H5 WebView 与桥接、配置加载、会话管理、预加载、离线资源缓存及语义 JSON 原生回退渲染。

## 安装

要求 iOS 16+、Swift 5.9+。在 Xcode 的 File → Add Package Dependencies 中添加：

```
https://github.com/VivaProjects/PaywallKit-iOS.git
```

选择版本 `0.1.1`，并将 `PaywallKit` 产品添加到 App target。代码中使用 `import PaywallKit`。

也可在宿主 Package.swift 中配置：

```swift
.package(url: "https://github.com/VivaProjects/PaywallKit-iOS.git", exact: "0.1.1")
```

宿主 target 添加 `.product(name: "PaywallKit", package: "PaywallKit-iOS")`。私有仓库接入需要 GitHub 读取权限。

## 接入与职责

- [H5 与宿主接入](docs/WEB_PAYWALL.md)
- [原生 JSON 回退接入](docs/INTEGRATION.md)
- [版本记录](CHANGELOG.md)

宿主负责商品目录、可信来源、StoreKit 查询、购买、恢复和权益验证；SDK 不内置业务服务地址、商品绑定或 H5 页面。页面包和配置由宿主提供。原生仅向 H5 提供商店价格及披露、适用资格、允许的环境字段和会话 custom；页面文案由 H5 content.json 维护。

此仓库只发布 iOS SDK。版本通过语义化 Git tag 管理，SDK 版本与桥协议版本分别维护。仓库未授予开源许可证，使用权限由仓库所有者决定。

## 构建

在 macOS 和 Xcode 环境下执行：

```sh
xcodebuild -scheme PaywallKit -destination 'generic/platform=iOS Simulator' -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme PaywallKit -destination 'generic/platform=iOS' -configuration Release CODE_SIGNING_ALLOWED=NO build
```

构建检查不代替宿主集成、真机购买与恢复验证。

版本由 `VERSION` 管理，发布流程见 [发布说明](docs/RELEASING.md)。
