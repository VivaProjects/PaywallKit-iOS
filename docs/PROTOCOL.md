# 协议与分发契约

## 文档

`protocol/paywall.schema.json` 是结构事实源，`tools/generate_contract.py` 是可维护定义源，生成本仓库的 Schema、组件目录和当前平台资源副本；其他实现通过各自仓库更新兼容快照。生成器不覆盖示例文件；修改示例时应同步复制到两端资源目录。双端使用同一受限 Schema 方言，没有任意表达式解释器。

根 `paywallScreen` 的 `children` 是语义组件序列；`purchaseBar` 必须放在 `bottomBar`。首版 informationSection 使用标题、正文和可折叠标志，不开放自由嵌套。此子集树深最多 2，满足方案最大深度 8 的上限。正文最多 12 项，整体节点上限 80，列表最多 12 项，单文案最多 2000 Unicode scalar/code point，未压缩文档最多 256 KiB。

必须且只能有一个 productPicker、一个 legalActions 和一个 purchaseBar；closeButton 最多一个；nodeId 全局唯一。所有字段按组件逐一白名单。unknown field/type/action/capability 一律整页拒绝。关闭权限来自宿主；法律文案、路由和恢复购买入口不可被普通内容配置替换。

组件的 requiredCapabilities 从组件目录读取。minimumRendererVersion 当前双端均为 1；客户端拒绝超过自身版本的文档，编辑器拒绝目录未支持的版本。更高能力应先升级 Schema 和双端实现。

本地化内联到文档：按完整 locale → 逐段去掉 region/script → defaultLocale，逐键合并。默认语言必须完整，部分翻译在编辑器产生回退警告。调用方传入 BCP-47 标识，例如 `zh-Hans-CN`；`_` 转成 `-`，大小写应由宿主规范化。法律和加载/错误文案使用 SDK 的宿主可配置 RuntimeCopy。

商品配置只有 `catalogKey` 和选择策略。宿主 catalog 定义 productRef 集合，商店桥将其映射为真实商品，并返回名称、价格字符串、订阅周期/续费披露。远端不包含商品价格、真实产品 ID、offerToken、货币或权益结论。

## 与独立分发服务的边界

编辑器导出 Schema 所定义的普通 UTF-8 JSON，不附加账号或发布信息。独立服务端可以原样分发，也可以使用自己的响应包裹；宿主从响应中取出文档后交给 SDK 的 `decodeDocument`。

协议只约定内容结构，不定义服务端 URL、数据库、鉴权、审批、签名算法或灰度流程。revision 由配置管理流程维护；SDK 不根据 revision 自行选择远端版本。

宿主完成传输层校验、来源验证、下载限额及超时，再调用 SDK。SDK 验证文档大小、Schema、能力、placement、资源、商品注册表及默认语言，成功后构造不可变 Snapshot。一次展示固定使用一个快照，避免购买中切换文案或商品集合。

失败时由宿主依次选取最近可用配置、Bundle JSON 或固定原生支付墙；任何 JSON 来源都必须经过同等解码校验。SDK 不伪造商店商品或交易结果。

历史签名与分桶测试向量保留在 `protocol/vectors.json`，仅供已有可选远端适配器兼容性检查，不是新服务端的必选协议。


Web H5 bootstrap 的 `environment.runtimeEnvironment` 为可选字符串枚举 `test` / `production`，缺失按 `test` 处理，非法值拒绝。该字段属于桥接 v2 的兼容扩展；其他环境字段、交易与商品精确 ID 规则保持不变。环境在会话内冻结，并参与配置及 WebView 缓存身份。

`environment.placement` 为可选的实际会话点位字符串，缺省为空；由宿主解析点位后注入。H5 只读取，不决定路由，桥接版本保持 v2。
