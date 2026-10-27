# 商品共有价格信息（桥协议 v2 兼容扩展）

`products[].subscriptionPricing` 是可选的结构化商店数据。旧字段保留，旧宿主不提供时必须省略；缺省不等于“无优惠”或“不符合资格”。Android 默认桥新增官方 Billing 依赖，Flutter 状态管理与路由依赖不变。

```json
{
  "phases": [
    {
      "priceAmount": "7.99",
      "currencyCode": "EUR",
      "displayPrice": "7,99 €",
      "billingPeriod": "P1M",
      "billingCycleCount": 1,
      "recurrenceMode": "finiteRecurring"
    },
    {
      "priceAmount": "19.99",
      "currencyCode": "EUR",
      "displayPrice": "19,99 €",
      "billingPeriod": "P1M",
      "billingCycleCount": 0,
      "recurrenceMode": "infiniteRecurring"
    }
  ]
}
```

- `phases`：原生确认可用、且实际购买采用的完整方案，按收费顺序排列。没有优惠时只有常规阶段；免费试用阶段金额为 `0`。
- `priceAmount`：非负十进制字符串，不含货币符号或千位分隔符，不使用浮点数。
- `currencyCode`：商店 ISO 4217 币种代码；同一方案必须同币种。
- `displayPrice`：商店格式化的本地化价格，H5 直接显示。
- `billingPeriod`：商店周期，ISO 8601 单一单位，如 P7D、P1W、P1M、P3M、P1Y。
- `billingCycleCount`：有限重复阶段为正整数；无限续订和不续订阶段为 0，后者仍有一次购买对应的有效周期。
- `recurrenceMode`：finiteRecurring / infiniteRecurring / nonRecurring。不续订或无限续订阶段只能位于末尾。

## 资格与购买边界

这不是优惠历史，也不增加“是否曾使用首月优惠”字段。原生必须在确认资格和选定购买方案后构造数据；不得把所有候选优惠同时交给 H5 选择。H5 不推断资格、不替换商品、不使用最低候选报价决定购买。offerToken、basePlanId 和平台签名由原生保存，实际购买必须与展示的报价方案一致。

`P1M`、有限阶段次数 1、正金额，才可在业务确认其为首期优惠后描述“首月价格”。免费试用不能显示为付费首月优惠，P3M 不能显示为首月。常规续订价格取随后阶段，不能把首期价格当续订价格。零价格阶段的免费文案、页面翻译在 H5 的 content.json 中维护；不能从格式化价格反向解析金额。

## iOS

默认 PaywallStoreKitProductMapper 自动填充结构化价格，优惠先经 StoreKit isEligibleForIntroOffer 检查。payAsYouGo 保留 periodCount；freeTrial / payUpFront 使用完整优惠周期、一次收费阶段。后接正常订阅阶段。自定义购买桥需要自行填充 PaywallSubscriptionPricing。默认转换器只覆盖入门优惠，不声称支持所有促销或赢回优惠。

## Flutter / Android

Flutter iOS 默认 StoreKit 通道自动携带新数据。Android 使用 SDK 默认桥，不再由宿主手动组装商品价格或注入优惠开关：

```dart
final bridge = PaywallGooglePlayPurchaseBridge(
  verifyPurchase: (purchase) async {
    // 调用宿主已有后端，验证 token、商品、账户和权益并完成发放。
    return await verifyAndGrantEntitlement(purchase.purchaseToken, purchase.productIds);
  },
);
// 将 bridge 传给既有支付墙入口；H5 仍只绑定 productRef。
// 销毁所有使用该 bridge 的会话后：await bridge.dispose();
```

SDK 自动查询 Play 返回的当前可用方案：同一商品一个基础套餐时优先选择优惠；多个可用优惠按 offerId 字典顺序稳定选择，不宣称是最便宜方案。没有优惠则只返回基础套餐的阶段。多基础套餐、分期计划不做猜测或丢弃承诺条件，应调整商店商品配置或继续使用自定义原生桥。这里的默认优惠必须是 **Google Play 管理资格的优惠**；开发者自定义资格不会因查询返回而自动得到验证，不能用于该默认桥。协议无法从 ProductDetails 判断开发者自定义资格条件。

购买前重新向 Play 查询选中方案，token 或价格阶段发生变化时抛出 `billing_quote_changed`，页面应重新加载商品，不静默改为正常价。商店可能在最终确认时再次检查资格，因此用户最终确认的商店购买页仍是交易依据。购买令牌、quoteId 与验单证据不会传入 H5。取消或 pending 不发放权益；成功交易经宿主验证后才 acknowledge 并报告成功。延迟付款完成、进程重启等场景应调用 `restore()` 恢复并验单；恢复结果必须由后端确认有效权益。

每个桥实例拥有独立报价身份，释放后迟到回调无效；引擎只有一个 SDK BillingClient，卸载引擎时关闭连接。原生重查询 30 秒超时、购买等待 5 分钟超时。宿主应避免同时让旧购买实现和默认桥处理同一交易。旧自定义桥仍可使用 PaywallPricingPhase.fromGooglePlay 转换数据，但不是默认接入所必需。

## H5 显示约定

SDK 默认映射的一个商品：`subscriptionPricing.phases.length > 1` 表示有可用优惠阶段；只有一个阶段显示正常价。首阶段金额为 0 显示免费试用；正金额且 P1M、1 次表示首月优惠；其他期限使用相应文案。续订价取最后一个阶段。字段缺失或商品加载失败显示加载/不可用，不推断没有优惠。所有金额使用阶段 displayPrice，文案由 content.json 维护，不需要 custom.hasOffer 或宿主额外注入资格开关。

## 兼容、预览与验收

这是可选字段扩展，bridgeVersion 仍为 2；现有 displayPrice/disclosure 等字段不改变。H5 需要另行接入新字段后才能动态显示，更新 SDK 不会自动改掉旧页面的固定美元文案。缺少结构化字段时沿用旧展示能力，不能编造优惠。Flutter 缓存比对覆盖所有阶段，报价或优惠周期变化会使旧表面失效。

浏览器 product-host 直接透传 products（包括 subscriptionPricing），演示数据可使用同目录 subscription-pricing.example.json；只供预览，不代表真实商店报价或资格。业务页面和美元演示价格不在此次 SDK 更新中修改。
