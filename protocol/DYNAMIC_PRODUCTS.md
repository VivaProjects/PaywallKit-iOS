# H5 动态商品请求

支持 productRequest 的页面在 sessionContext 后发送 productsRequest，可请求清单之外的商店商品 ID。清单用于旧页面兼容，不再限制桥接请求集合。每次会话只接受一次商品请求，最多 100 个非空、去重 ID，每个最长 256 字符；bridgeVersion、sessionID、runtimeEnvironment 必须匹配当前会话。

支持 deferredProducts 和 renderReady 的页面先接收空 products 的 bootstrap，商品返回后接收 productsUpdated；即使 waitsForProducts 开启也采用此流程。旧页面仍等待查询完成。商品未返回时显示占位并禁用购买；不使用演示价格。仅本次请求且商店实际返回的商品可进入购买，宿主负责商店查询、资格、购买及验单。宿主自己的查询或购买白名单也需配合调整。

浏览器预览仅返回预览商品表中有演示报价的 ID，不伪造未知商品报价。未发布 SDK 或页面包。
