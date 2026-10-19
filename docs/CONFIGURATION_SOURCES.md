# Custom configuration sources (iOS)

## Preferred: query API

`PaywallClient(query:catalog:retainedPlacements:)` owns the POST protocol and lifecycle. The host supplies endpoint, runtime environment, a cache namespace, approved resource origins, supported server-to-host placement mappings, and its registered product catalog. Optional `PaywallQueryFallback` declares the bundled resource directory and the placements that can use it; the host does not construct or refresh package stores.

```swift
let client = PaywallClient(
    query: .init(
        endpoint: URL(string: "https://api.example.com/app/paywall/query")!,
        runtimeEnvironment: .test,
        cacheNamespace: "Example.test",
        allowedOrigins: ["https://cdn.example.com"],
        placements: ["banner": "banner", "settings": "settings"],
        fallback: .init(
            placement: "settings",
            bundledDirectory: Bundle.main.resourceURL!.appendingPathComponent("Fallback"),
            fallbackPlacements: ["banner"]
        )
    ),
    catalog: { registeredCatalog },
    retainedPlacements: ["banner", "settings"]
)
// Forward the attribution provider's callback; nil + failed=false means organic.
client.reportAttribution(channel: mediaSource, failed: attributionFailed)
// Prepare at startup; existing resolve, presentation, purchase and restore APIs stay unchanged.
try await client.prepare()
```

The optional `PaywallQueryConfiguration(waitUntilNetworkAvailable:)` async throwing closure lets the host reuse its connectivity monitor. It must return only when online and propagate task cancellation. The SDK calls it before collecting attribution/storefront conditions and again immediately before sending the POST; it should be safe to call repeatedly and return immediately while online. Offline or unknown connectivity waits within the single shared task without consuming the five-second attribution window or retaining an offline failure. Restored snapshots and bundled fallbacks remain available. Network recovery continues that same task; it does not enable retries after a request has failed. Omitting this closure preserves the existing direct-request behavior. Path availability does not guarantee the endpoint is reachable; request failures still follow the existing fallback policy.

The SDK automatically scopes the supplied cache namespace by runtime environment, so configuration, attribution and package state cannot cross environments even when a host reuses a namespace. The SDK waits up to five seconds for an unknown channel, falls back to `organic`, and persists confirmed attribution only. It gathers app version and passes system values through unchanged: `device_type` uses the same concrete hardware model identifier as the H5 environment (for example `iPhone17,1`); simulators use `SIMULATOR_MODEL_IDENTIFIER`, `language` uses `Locale.preferredLanguages.first` (for example `en-US`), and `country` uses `Storefront.current.countryCode` (for example `USA`). Missing language or country is sent as an empty string. This does not change the H5 bridge country contract. Only the query uses these wire field names.

The response adapter understands `code`, `data`, `positionKey`, `matched`, `h5Url` and `displayModeKey`. Only mapped matched placements are accepted. Package metadata determines products and revisions; full package verification precedes configuration caching. Malformed business responses fail. A valid empty list or a list without usable supported placements produces an empty configuration. Unavailable page packages are skipped independently. The host excludes placements that need unsupported business policies rather than synthesizing permissions.

The query client restores complete per-placement launch snapshots before any presentation selects its mode. Cached placements use verified local packages without waiting for attribution, storefront collection, the configuration request or H5 downloads. Configuration, product references, presentation and original request identity are cached; current StoreKit prices, eligibility, entitlement and transaction objects are not. Each restored placement remains frozen for this client lifetime, including repeated openings and preloads. Snapshots are isolated by namespace, environment, endpoint, app version, device and language. Channel or country changes affect the background request rather than invalidating this launch's cached decision.

Keep one client for the App process. Startup preparation and all missing placements share one query task, retaining success or failure without automatic retry. Valid network results can fill placements missing at launch; updates to already cached placements are archived for the next cold start only. A missing or corrupt placement keeps the existing in-screen loading, bundled fallback, retry or skip behavior. Other placements remain immediately usable even if the query fails. Later entries, page retries, foreground activation, attribution changes, `refresh()` and `invalidateConfiguration()` never start another query.

After a valid response is decoded, registered placements that are omitted, explicitly unmatched, or cannot form a download candidate immediately resolve as missing when they have no launch snapshot. Waiting callers resume before package downloads finish and follow their existing fallback or skip policy. Matched placements continue downloading on the shared task. Launch snapshots remain frozen, and only explicit `matched=false` entries remove next-launch snapshots under the existing policy. The diagnostic event `query.placement_unavailable` identifies these early resolutions.

Each unique H5 URL is prepared once per response, then all of its mapped placements are committed independently before the next package starts. Missing-placement callers resume as soon as their own placement is ready; startup preparation with no cached placements returns after the first complete placement. Remaining packages continue on the same background task. Active presentation waits for its complete placement result without the 12-second presentation deadline; product and web preparation receive a fresh deadline after resolution. The current container keeps the mode frozen when it opened; a subsequent opening uses the newly cached placement mode. Definitive query failure or a missing placement still follows fallback policy. Cancelling one waiting caller removes only its subscription. Empty responses, failures and cancellation finish all remaining waiters. A later package cannot delay persistence of a completed package or discard that completed placement if the process exits early.

Complete packages are copied and verified before atomically committing the next-launch index. Active leases protect this launch's files, and the persisted index protects the next launch's files from ordinary resource-cache eviction. Each placement is stored independently, so two versions of the same document identifier cannot overwrite each other. Explicit `matched=false` removes only the next-launch entry; malformed business responses and failed page packages preserve valid cached entries. The current fallback snapshot and preload identity never change when the update finishes. Old v2 configuration caches migrate only after the exact current request identity is available and the full package already exists locally; URL-only or guessed request identities are never used.

The first background request freezes attribution and storefront conditions. Late confirmed attribution is persisted without another query. Background update success or failure is diagnostic-only and never opens or reopens a page. The coordinator owns the query task and retains its client weakly. Query-specific code is internal except the existing declarative structs and client entry points; custom configuration source policies and H5 bridge/Flutter APIs are unchanged. No attribution SDK or application-specific domain, placement or product identifier is bundled in the SDK.

## Advanced: custom configuration source

`PaywallConfigurationSource` accepts an async URLRequest factory. Existing endpoint/parameters convenience initializers continue to issue GET requests without a response adapter.

For a business POST API, supply:

- `requestIdentity`: a stable identifier covering endpoint, method, environment and the canonical request body. A digest avoids retaining request parameters in cache keys.
- `runtimeEnvironment`: explicit `test` or `production` when the request no longer carries that value in the URL.
- `responseTransform`: async conversion of a successful HTTP body to the existing web-paywall configuration JSON. The transformed configuration is validated and cached; offline reads do not rerun the network-dependent adapter.
- `isCurrentRequest`: reject a response whose host-side conditions have changed. Rejection cancels the obsolete request without reading its cache.

POST requests do not migrate legacy URL-only caches. GET sources still read their legacy cache keys. Successful history uses the supplied request identity too. A normalized empty placement/paywall map is supported to represent an explicit no-match result; business error/empty-response policy belongs in the adapter.

`WebPaywallPackageLoader.load` accepts an approved HTTPS index.html URL, environment, allowed origins and product catalog. It checks the colocated package index, validates its exact page identity, downloads and verifies all resources, and returns the remote document. It never invents a revision or product binding. The package must already be fully published. Background package validation allows up to 120 seconds per package; ordinary on-screen preparation retains its existing default timeout and the presentation deadline still controls fallback.

For custom configuration sources, `PaywallClient.invalidateConfiguration()` cancels obsolete loading and clears the in-memory configuration. Waiting callers continue with the new generation; previously presented sessions retain their own immutable snapshot. The host should also include changed business conditions in its preload cache identity. `refresh()` coalesces concurrent callers and does not preserve an unrelated stale in-memory configuration on failure; the source can still recover a valid same-identity disk snapshot. These refresh/invalidation behaviors do not apply to the preferred query client, which retains its launch snapshots and its single background task result.

`PaywallLocalPackageStore` now accepts a nil updateURL for bundled-only or host-driven updates. `adopt(document)` verifies a complete package before atomically updating the local pointer, retaining the previous version. Scope each store by the host request identity and reuse it during the process lifetime; never repeatedly initialize a store over files held by live sessions. Published revisions must increase, and published directories must be immutable.

No H5 bridge payload or Flutter API is changed.

## Local Debug testing

`PaywallQueryConfiguration(developmentHTTPOrigin:)` explicitly permits one HTTP origin for the query, package metadata, configuration validation and fallback update path in Debug + Test only. Release or production ignores this option. Page packages still require complete resource hashes and matching product bindings. The host must supply local networking permission and deploy complete immutable packages, not source directories.

### 测试时清理启动缓存

宿主测试入口可调用 `PaywallCacheMaintenance.clearOnNextLaunch()`，提示用户完全关闭并重新打开 App。下一进程首次创建查询 Client 前会清理 SDK 启动快照、H5 资源、历史包及旧 v1/v2 配置；归因、权益和宿主数据不清理。清理标记仅在成功后移除，失败会记录日志并保留下次重试。当前进程不销毁活跃资源，也不新增配置请求。此入口应只暴露在测试工具中。

### 查询页面下载调度

查询运行时最多并行准备两个页面包，每包最多四个资源请求；相同 URL 合并下载，各点位完整校验和归档后立即可用。可见入口将当前点位提升到待下载队列首位（占用下一个空闲槽，不中断正在下载的包）；后台预加载不覆盖点击优先级。仍只查询一次配置，已有缓存本次冻结、新包下次启动生效，单包失败不影响其他包。通用配置转换保留顺序准备页面包。
