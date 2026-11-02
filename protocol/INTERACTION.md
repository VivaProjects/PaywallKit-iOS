# H5 交互反馈（bridgeVersion 2，可选）

H5 负责按压缩放，SDK 只通知宿主。SDK 默认不震动；反馈不代表购买、恢复、选中或关闭已经成功，也不能改变商店价格、资格及商品绑定。

页面对可交互目标显式设置稳定的 `data-feedback` 标识。按下缩至 0.92，释放或取消后约 400ms 回弹；减少动态效果模式保留通知、关闭缩放。禁用、加载、隐藏时无反馈。滚动、拖动、取消和失焦会复位，已发送的反馈不撤销。键盘及辅助技术激活每次最多通知一次。

```json
{"type":"interaction","bridgeVersion":2,"sessionID":"current-session","presentationID":3,"targetID":"purchase","action":"purchase","productRef":"annual"}
```

- 必填：`type`、`bridgeVersion`、`sessionID`、`targetID`、`action`。`targetID` 为页面内稳定、非空、最长 160 字符的控件标识，不包含文案。
- `action`：`purchase`、`restore`、`close`、`terms`、`privacy`、`select`（商品选项）、`toggle`（页面展开）、`dismissDetails`（详情关闭）。
- `productRef` 可选；提供时必须属于当前会话已注入的有效报价。`select` 必须提供，购买反馈提供当前商品。它不触发交易。
- `presentationID` 可选；原生 `presentationState` 提供时原样回传，用于拒绝缓存页上次展示的延迟消息。
- 仅当前已展示、渲染完成、非交易中的会话向宿主回调。预加载、退场、失效会话和格式错误消息静默忽略；反馈不排队、不重放，无需回执。
- 旧 SDK 忽略未知消息，新 SDK 继续支持不发送反馈的旧 H5。保持协议 v2，不增加 bootstrap 展示字段或第三方依赖。

H5 同步完成视觉反馈，并独立发送已有业务桥动作；不等待宿主反馈完成。宿主不应在反馈回调中执行购买、关闭或修改会话。
