# iOS 本地付费墙更新与兜底

宿主通过 PaywallClient.useLocalPackages(PaywallLocalPackageStore) 注册本地入口、允许降级的主动点位、App 基础资源目录、独立更新 URL、环境及商品目录。SDK 不内置业务点位名称。普通 resolve/preload 不主动触发兜底；正式展示共享一次降级上下文。

## 包与会话

复用 package.json / offline.html / offline.js，按环境、清单、商品目录、路径、大小和 SHA-256 完整校验。基础目录必须属于 App Bundle；Release 更新要求受信任 HTTPS 来源。包只保存静态资源与商品绑定，不保存实际价格、资格或 WebView 会话。

本地入口读取有效更新包、上一有效包或内置包，不等待网络。refreshIfNeeded() 在冷启动首次及前台恢复间隔一小时执行，返回本次是否成功检查；宿主随后可调用 client.refresh() 刷新完整配置。下载在临时目录完成校验后原子切换指针，只影响新会话。版本目录独立于普通缓存，历史目录在下次进程初始化清理以保护正在使用的页面。

查询模式主动入口等待配置与完整点位缓存最多 3 秒，超时进入已注册的本地兜底，后台任务继续下载和有限重试。超时点位本次启动保持兜底，迟到的新包下次冷启动生效。配置就绪或开始本地兜底后，商品与网页准备另计原有 12 秒期限；3 秒不包含 StoreKit 或页面渲染耗时。本次容器保持打开时的展示形态；明确失败或无匹配点位仍进入兜底。本地降级获得自己的首屏期限。PaywallFailure 区分配置、缺失、关闭、资源、Bridge、超时、商品、取消和业务资格失效。只有页面或配置故障可自动降级。更新包资源/Bridge 故障隔离版本并改用内置包，商品查询失败不隔离资源。原点位最多降级一次，更新包最多再退内置包一次；用户重试保留当前分支。

新增 PaywallSessionEvent.resolved(PaywallResolution)，提供原始点位、实际文档、版本、资源来源与原因。消费方穷举 switch 需要处理该事件；只有 ready 才可记录曝光。WebPaywallView 增加可选结构化失败、资源来源与总期限参数，旧调用保持兼容。H5 Bridge 消息协议不变，environment.placement 仍表示实际请求入口。本次本地策略仅接入 iOS；Flutter 保持原协议。
