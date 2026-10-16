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

The SDK automatically scopes the supplied cache namespace by runtime environment, so configuration, attribution and package state cannot cross environments even when a host reuses a namespace. The SDK waits up to five seconds for an unknown channel, falls back to `organic`, and persists confirmed attribution only. It gathers app version and passes system values through unchanged: `device_type` uses the same concrete hardware model identifier as the H5 environment (for example `iPhone17,1`); simulators use `SIMULATOR_MODEL_IDENTIFIER`, `language` uses `Locale.preferredLanguages.first` (for example `en-US`), and `country` uses `Storefront.current.countryCode` (for example `USA`). Missing language or country is sent as an empty string. This does not change the H5 bridge country contract. Only the query uses these wire field names.

The response adapter understands `code`, `data`, `positionKey`, `matched`, `h5Url` and `displayModeKey`. Only mapped matched placements are accepted. Package metadata determines products and revisions; full package verification precedes configuration caching. Malformed business responses fail. A valid empty list or a list without usable supported placements produces an empty configuration. Unavailable page packages are skipped independently. The host excludes placements that need unsupported business policies rather than synthesizing permissions.

The query client loads configuration at most once during its lifetime. Keep one client for the App process: startup preparation, preloading and presentation all share the same task and reuse its success or failure result. Network failure first recovers a valid same-request disk snapshot; without one, presentation immediately follows the host-declared bundled fallback or missing-placement policy. Later entries, page retries, foreground activation, attribution changes, `refresh()` and `invalidateConfiguration()` never start another query. A new App process creates a new client and may query once again.

The first request freezes its attribution and storefront conditions. Late confirmed attribution is persisted for the next App launch without invalidating the current response or cache. A successful network or disk load still schedules the fallback package update; H5 metadata and resource downloads are separate from the single configuration query. The coordinator owns its package-update task and retains its client weakly. Query-specific code is internal except the declarative configuration and fallback structs and the client entry points. No attribution SDK or application-specific domain, placement or product identifier is bundled in the SDK.

## Advanced: custom configuration source

`PaywallConfigurationSource` accepts an async URLRequest factory. Existing endpoint/parameters convenience initializers continue to issue GET requests without a response adapter.

For a business POST API, supply:

- `requestIdentity`: a stable identifier covering endpoint, method, environment and the canonical request body. A digest avoids retaining request parameters in cache keys.
- `runtimeEnvironment`: explicit `test` or `production` when the request no longer carries that value in the URL.
- `responseTransform`: async conversion of a successful HTTP body to the existing web-paywall configuration JSON. The transformed configuration is validated and cached; offline reads do not rerun the network-dependent adapter.
- `isCurrentRequest`: reject a response whose host-side conditions have changed. Rejection cancels the obsolete request without reading its cache.

POST requests do not migrate legacy URL-only caches. GET sources still read their legacy cache keys. Successful history uses the supplied request identity too. A normalized empty placement/paywall map is supported to represent an explicit no-match result; business error/empty-response policy belongs in the adapter.

`WebPaywallPackageLoader.load` accepts an approved HTTPS index.html URL, environment, allowed origins and product catalog. It checks the colocated package index, validates its exact page identity, downloads and verifies all resources, and returns the remote document. It never invents a revision or product binding. The package must already be fully published. Background package validation allows up to 120 seconds per package; ordinary on-screen preparation retains its existing default timeout and the presentation deadline still controls fallback.

For custom configuration sources, `PaywallClient.invalidateConfiguration()` cancels obsolete loading and clears the in-memory configuration. Waiting callers continue with the new generation; previously presented sessions retain their own immutable snapshot. The host should also include changed business conditions in its preload cache identity. `refresh()` coalesces concurrent callers and does not preserve an unrelated stale in-memory configuration on failure; the source can still recover a valid same-identity disk snapshot. These refresh/invalidation behaviors do not apply to the preferred query client, which retains its first task result.

`PaywallLocalPackageStore` now accepts a nil updateURL for bundled-only or host-driven updates. `adopt(document)` verifies a complete package before atomically updating the local pointer, retaining the previous version. Scope each store by the host request identity and reuse it during the process lifetime; never repeatedly initialize a store over files held by live sessions. Published revisions must increase, and published directories must be immutable.

No H5 bridge payload or Flutter API is changed.

## Local Debug testing

`PaywallQueryConfiguration(developmentHTTPOrigin:)` explicitly permits one HTTP origin for the query, package metadata, configuration validation and fallback update path in Debug + Test only. Release or production ignores this option. Page packages still require complete resource hashes and matching product bindings. The host must supply local networking permission and deploy complete immutable packages, not source directories.
