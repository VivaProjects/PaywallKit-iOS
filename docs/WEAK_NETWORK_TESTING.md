# 弱网更新回归

在 SDK 根目录启动仅监听本机的夹具服务器：

```sh
python3 tools/weak_network_fixture_server.py
```

另一个终端执行（将目标 ID 替换为可用的 iOS Simulator）：

```sh
xcodebuild -scheme PaywallKit \
  -destination 'platform=iOS Simulator,id=0687E363-BD44-43AE-8205-F4B326294EFF' \
  -parallel-testing-enabled NO test
```

服务器未运行时，新增的网络用例跳过。用例使用唯一 namespace 和文档 ID，不访问业务服务器；执行后关闭夹具服务器。配置请求通过 URLProtocol 控制，页面资源通过本机 HTTP 服务走实际 URLSession 下载与摘要校验。独立 SDK XCTest 没有宿主资源 Bundle，兜底用已验证的本地启动快照，未覆盖 App 内置包的真实 Bundle 路径。

## 2026-10-23 验证结果

环境：iOS 26.5，iPhone 17 Pro Max Simulator，SDK 0.3.2。

18 项通过、0 失败、0 跳过：新增 13 项，既有响应解析 5 项。

- 配置 503：2 秒、5 秒退避后成功；持续失败恰好请求 3 次，仅报告一次最终失败。
- 资源包 503：退避后成功，仅报告一次完成。
- 入口约 3 秒返回本地兜底；4 秒迟到配置继续完成下载并落盘，当前 Client 不启用，新 Client 恢复。
- 已有 v1 快照收到 v2 后仍保持 v1，新 Client 恢复 v2。
- 相同发布身份与展示方式返回更新数 0；空响应返回 0。
- 单包失败与部分成功分别报告正确计数，不误报全部成功。
- 打印开关不影响更新诊断回调；SDK 默认记录，关闭打印仍可读取或导出。
- 取消入口不取消后台任务；取消退避不继续重试；校验错误与不可恢复 HTTP 不重试。

测试验证的是 SDK 诊断事件及生命周期，不等于四类 Toast 均已做视觉验收，也不包含真机 StoreKit 购买、真实蜂窝弱网、iOS 16–25 或 iOS 26 真机视觉与交互验收。

## App 提示实测

同一 iOS 26.5 模拟器安装 Debug-Test App（依赖 SDK 0.3.2），冷启动访问既有测试服务。日志确认 `query.update_finished updated=0 unmatched=0 failures=0`；启动后约 1.8 秒截图确认底部显示“支付墙已是最新，无需更新”，文字完整可读。截图保存在 `/tmp/paywall-toast-2.png`。其余三类提示本轮验证了 SDK 事件与计数，未逐一截图验收。

## 三类 Toast 截图补验（2026-10-23）

iOS 26.5 / iPhone 17 Pro Max Simulator，SDK 0.3.2，临时 Debug App 仅将服务地址切至独立本机服务。使用实际 Settings 页面包的 19 个资源；未手动注入 Toast 回调。未修改原业务服务器。

| 场景 | 实际网络条件 | 截图确认文案 |
| --- | --- | --- |
| 下载完成 | 完整下载并校验一个新版本页面包 | 支付墙下载完成，更新已保存 |
| 部分失败 | Settings 新包成功；另一点位 package.json 返回 404 | 支付墙更新：1 个点位完成，1 项失败 |
| 最终失败 | 查询连续返回 503，共 3 次请求，退避约 2 秒、5 秒 | 支付墙更新失败，继续使用本地版本 |

三种 Toast 均实际出现、文字完整可读。最终失败场景验证的是查询阶段重试耗尽，不表示模拟了资源流传输中断；资源包重试已由 SDK 自动化用例覆盖。上述三项替代此前“其余三类未逐一截图”的限制。真机和旧系统视觉验收仍未执行。

截图与请求记录目录：`<本地验证产物目录>/paywall-toast-validation/`，分别为 `success.png`、`partial.png`、`failure.png`、`requests.jsonl`。

临时测试后已校验原配置源码逐字恢复，恢复原模拟器 App 与构建产物；独立本机测试服务器已关闭。
