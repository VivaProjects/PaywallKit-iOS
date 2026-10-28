# 支付墙真机耗时诊断

## 开启与采集

SDK 默认独立记录 test 和 production 日志，不依赖宿主日志服务。控制台默认不打印，关闭打印仍可读取或导出：

```swift
PaywallLogging.printsToConsole = false // 默认；仅控制打印
let text = await PaywallLogging.read()
let fileURL = try await PaywallLogging.export()
// try await PaywallLogging.clear()
```

需要实时查看时将 `printsToConsole` 设为 `true`，筛选 `[PaywallKit]`。兼容旧 `mode`：`enabled` 打印，`automatic` / `disabled` 不打印；所有模式均记录，更新诊断回调也不受打印开关影响。开关不改变业务环境。

日志后台写入应用私有目录，保留三个各不超过 1 MiB 的滚动文件，旧记录自动淘汰；待写缓冲上限 128 KiB，另有最多一批在途写入。单条超长日志会截断。`read()` 等待已有写入后读取保留记录；`export()` 覆盖一个独立本地快照（额外约 3 MiB），由宿主自行分享，不自动上传；`clear()` 只清日志，后续继续记录。

iOS 使用 Application Support/PaywallKit/Diagnostics，排除系统备份；页面缓存清理保留日志。磁盘不可写时使用有界内存缓冲，读取可见 `logs.storage_unavailable`；溢出记录 `logs.dropped`。后台写入为尽力保存，强制终止进程可能丢失尚未落盘的末尾记录，存储故障期间的内存记录不会跨启动保留。

开启日志不改变 runtimeEnvironment。不要为采集日志把 production 改成 test。配置请求只记录方法、响应状态/长度和耗时，不再打印原始请求体、响应体。新增计时不输出价格、custom 或交易凭据。

## 关联与读取

- `sdk` 区分实现；`tMs` 为单调时钟时间，不是日历时间。只在同一进程/运行实例内比较；Flutter 与原生时钟起点不同，不能直接相减。`run` 区分运行实例，`wallMs` 是日历毫秒时间，供跨启动排序；计算阶段耗时仍使用单调时间。
- `span` 关联同一次阶段的 `.begin` / `.end`；`durationMs` 是该次阶段耗时，`status=ok/error` 表示完成或抛错。只有 begin 可能表示仍在等待、进程被停止或日志缺失，不能仅据此认定 SDK 卡死。
- `query` 区分查询运行时；`key` 区分完整页面包；`document`、`placement` 辅助定位页面与入口。
- `flow` 区分高层展示，`session` 区分 WebView；`flow.link` 将两者连接。低层 WebView 直接接入没有高层 flow；预热阶段也可能尚无 flow。缓存复用后 session 可以相同，以新的 flow/link/attach 为准。
- 配置环境尚未确定的自定义 iOS 配置源，可能没有选择或宿主准备的开始日志；成功后 `flow.prepared` 提供耗时摘要。宿主调用 SDK 之前的启动门禁不在 SDK 测量范围，应另外记录入口调用时间。

## 阶段定位表

| 日志 | 用途 |
| --- | --- |
| `query.network_wait` | 宿主联网等待 |
| `query.attribution` | 归因等待 |
| `query.environment`（Flutter）/ `query.storefront`（iOS） | 环境回调或商店国家采集 |
| `configuration.fetch`（Flutter）/ `configuration.request` → `configuration.response`（iOS） | Flutter 包含重试总等待；iOS 为单次网络请求，重试另看 `query.retry` |
| `snapshot.restore`、`local.verify`、`local.bundled_verify`、`resource.verify` | 快照恢复及本地完整性验证；不同路径只出现适用事件 |
| `resource.download_wait` → `resource.download_start` → `resource.download_ready` | 包下载排队与下载/校验/写盘；按 key 关联 |
| `archive.total`、`archive.acquired queueMs`、`archive.work`（iOS）/ `archive.copy_verify`（Flutter） | 归档总等待、队列等待及文件准备 |
| `snapshot.commit` | 索引提交；iOS 包含串行队列等待，Flutter 记录实际持久化调用 |
| `flow.selection` / `flow.prepared selectionMs` | 配置选择、缓存和回退准备的汇总 |
| `flow.host_prepare` / `flow.prepared hostPrepareMs` | 宿主资格与输入准备 |
| `webview.configure`、`webview.resource` | WebView 配置与其资源等待 |
| `navigation.start` → `navigation.finished` | 主文档导航；结束不代表业务可用 |
| `products.start` → `products.loaded/failed` | 商店查询及报价映射 |
| `bridge.received`、`bridge.send`、`render.ready` | H5 握手、数据发送与首屏回执 |
| `flow.render_observed totalMs` | 高层观察到首屏就绪的本次流程累计耗时 |

阶段会并行或嵌套，不能把全部 durationMs 相加。`resource.verify` 的失败可能只是缓存未命中，需结合后续下载、回退与最终失败事件判断。`renderReady` 是 H5 回执，不是显示器首帧实测。预加载耗时也不等于用户点击后的耗时：热打开看本次 attach/link 到 ready 的时间，并结合宿主入口时间。

## 真机测试场景

1. 首次安装、无缓存：记录设备、系统版本、网络和实际点位。
2. 有缓存冷启动：保留应用数据、终止进程后启动。
3. 同进程重复打开：确认是否复用 session，以及商品复核是否发生。
4. 弱网或离线：记录超时、回退来源及恢复联网后的结果。

各场景重复数次，保留完整原始日志；比较中位数和明显慢例。先看最长等待落在哪个阶段，再决定是否需要 Instruments、Web Inspector 或商店/网络专项分析。需要逐资源网络瀑布或 H5 内部脚本、图片、字体耗时时，使用相应平台工具；SDK 阶段日志不提供这些细分。
