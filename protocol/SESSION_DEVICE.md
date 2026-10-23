# 会话设备参数（桥协议 v2 兼容扩展）

`sessionContext.custom` 和 `bootstrap.custom` 平铺包含以下字段，不新增顶层 `environment`：

- `os`：字符串，仅 `iOS` 或 `Android`（区分大小写）。
- `isPad`：JSON 布尔值 `true` / `false`，表示是否平板；不能传字符串。

字段属于 SDK 冻结的适配环境，覆盖同名业务 custom，参与会话缓存身份。改变配置后须创建新会话。旧 H5 可忽略新增字段；H5 如兼容旧 SDK，应处理字段缺失。商品价格、资格与交易行为不受影响。交付清单 schema 不变。

```json
{"custom":{"os":"iOS","isPad":true}}
```

配置查询接口同样发送 `conditions.os` 和 `conditions.isPad`；POST 保留布尔类型，GET 查询参数编码为 `true` / `false`。
