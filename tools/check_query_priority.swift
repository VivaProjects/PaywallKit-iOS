import Foundation

// 只替换下载与接入配置；队列、分组、取消、点位交付使用生产实现。
struct PaywallQueryConfiguration {
    enum Environment: String { case test }
    let runtimeEnvironment = Environment.test
    let placements = ["a": "a", "b": "b", "c": "c", "d": "d", "e": "e", "f": "f"]
    let allowedOrigins: Set<String>? = ["https://example.com"]
    let developmentHTTPOrigin: String? = nil
    let waitUntilNetworkAvailable: (@Sendable () async throws -> Void)? = nil
}
enum WebPaywallConfiguration {
    enum Presentation: String { case fullScreen, sheet }
}
@MainActor
enum WebPaywallPackageLoader {
    static var calls = 0
    static var started: [String] = []
    static var failing: String?
    static var slow: String?
    static var active = 0
    static func prepare(pageURL: URL, runtimeEnvironment: String, allowedOrigins: Set<String>?,
                        catalog: PaywallCatalog, developmentHTTPOrigin: String?) async throws
        -> (WebPaywallDocument, WebPaywallResourceLease) {
        calls += 1
        let name = pageURL.deletingLastPathComponent().lastPathComponent
        started.append(name)
        active += 1
        defer { active -= 1 }
        if name == slow { try await Task.sleep(nanoseconds: 10_000_000_000) }
        if name == failing { throw WebPaywallError.invalidDocument }
        let identity = WebPaywallPackage.Document(kind: "web-paywall", bridgeVersion: 2,
            documentId: "shared", revision: 1, pageUrl: pageURL.absoluteString,
            catalogKey: "default", productRefs: ["product"], initialProductRef: "product")
        let document = try WebPaywallDocument(data: JSONEncoder().encode(identity), allowedOrigins: allowedOrigins, catalog: catalog)
        return (document, WebPaywallResourceLease(directory: FileManager.default.temporaryDirectory, release: {}))
    }
}

@main
struct QueryPriorityChecks {
    static let catalog = PaywallCatalog(productRefs: ["product"], recommendedRef: "product")
    static let bytes = Data(#"{"code":"200","data":[{"positionKey":"a","matched":true,"h5Url":"https://example.com/index.html"},{"positionKey":"b","matched":true,"h5Url":"https://example.com/index.html","displayModeKey":"sheet"},{"positionKey":"c","matched":true,"h5Url":"https://example.com/index.html"},{"positionKey":"d","matched":false}]}"#.utf8)

    /// 当前入口优先，交付期间改变入口仍生效；每个别名仅提交一次并保留展示方式。
    @MainActor
    static func main() async throws {
        var preferred: String? = "b"
        var delivered: [String] = []
        var unavailable: Set<String> = []
        let result = try await PaywallQueryResponse.load(bytes, configuration: .init(), catalog: catalog,
            maximumConcurrentPackages: 2, preferredPlacement: { preferred },
            onUnavailable: { unavailable.formUnion($0) }, onPage: { page in
                delivered.append(page.placement)
                if page.placement == "b" {
                    precondition(page.presentation == .sheet)
                    await Task.yield()
                    preferred = "c"
                }
            })
        precondition(delivered == ["b", "c", "a"])
        precondition(result.pages.map(\.placement) == delivered)
        precondition(result.pages.allSatisfy { $0.resource === result.pages[0].resource })
        precondition(unavailable == ["d", "e", "f"] && result.unmatched == ["d", "e", "f"])
        precondition(WebPaywallPackageLoader.calls == 1)
        let ordered = try await PaywallQueryResponse.load(bytes, configuration: .init(), catalog: catalog)
        precondition(ordered.pages.map(\.placement) == ["a", "b", "c"])
        print("PASS Swift same-package visible priority, dynamic priority, single load and independent presentation")
        try await checkPipeline()
        try await checkPrefetchCancellation()
        try await checkCancellation()
        do {
            _ = try await PaywallQueryResponse.load(bytes, configuration: .init(), catalog: catalog,
                onPage: { _ in throw WebPaywallError.invalidDocument })
            fatalError("Delivery failure swallowed")
        } catch WebPaywallError.invalidDocument {}
        print("PASS Swift alias cancellation and delivery failure semantics preserved")
    }

    /// 两个归档回调被阻塞时只允许两个额外预取，尚未领取的包继续遵守入口优先级。
    @MainActor
    static func checkPipeline() async throws {
        let names = ["a", "b", "c", "d", "e", "f"]
        let data = try JSONSerialization.data(withJSONObject: ["code": "200", "data": names.map {
            ["positionKey": $0, "matched": true, "h5Url": "https://example.com/\($0)/index.html"] as [String: Any]
        }])
        WebPaywallPackageLoader.started = []
        WebPaywallPackageLoader.failing = "c"
        let gate = VerificationGate(target: URL(fileURLWithPath: "/pipeline"))
        var delivered: [String] = []
        var preferred: String?
        let task = Task { @MainActor in
            try await PaywallQueryResponse.load(data, configuration: .init(), catalog: catalog,
                maximumConcurrentPackages: 2, preferredPlacement: { preferred }, onPage: { page in
                    delivered.append(page.placement)
                    if page.placement == "a" || page.placement == "b" {
                        await gate.before(URL(fileURLWithPath: "/pipeline"))
                    }
                })
        }
        for _ in 0..<1000 {
            if delivered.count == 2 && WebPaywallPackageLoader.started.count == 4 { break }
            await Task.yield()
        }
        precondition(Set(delivered) == ["a", "b"])
        precondition(Set(WebPaywallPackageLoader.started) == ["a", "b", "c", "d"])
        preferred = "f"
        await gate.open()
        let result = try await task.value
        precondition(result.failures == 1 && Set(delivered) == ["a", "b", "d", "e", "f"])
        precondition(WebPaywallPackageLoader.started.firstIndex(of: "f")! < WebPaywallPackageLoader.started.firstIndex(of: "e")!)
        WebPaywallPackageLoader.failing = nil
        print("PASS Swift bounded archive/download overlap, queued priority and prefetched failure")
    }

    /// 归档失败时取消仍在下载的预取，并等待子任务退出后返回。
    @MainActor
    static func checkPrefetchCancellation() async throws {
        let data = try JSONSerialization.data(withJSONObject: ["code": "200", "data": ["a", "b"].map {
            ["positionKey": $0, "matched": true, "h5Url": "https://example.com/\($0)/index.html"] as [String: Any]
        }])
        WebPaywallPackageLoader.started = []
        WebPaywallPackageLoader.slow = "b"
        defer { WebPaywallPackageLoader.slow = nil }
        do {
            _ = try await PaywallQueryResponse.load(data, configuration: .init(), catalog: catalog,
                maximumConcurrentPackages: 1, onPage: { page in
                    precondition(page.placement == "a")
                    for _ in 0..<1000 where WebPaywallPackageLoader.active == 0 { await Task.yield() }
                    precondition(WebPaywallPackageLoader.started == ["a", "b"])
                    throw WebPaywallError.invalidDocument
                })
            fatalError("Archive failure swallowed")
        } catch WebPaywallError.invalidDocument {}
        precondition(WebPaywallPackageLoader.active == 0)
        print("PASS Swift failed delivery cancels and drains in-flight prefetch")
    }

    /// 首个别名交付后取消，不允许后续别名提交。
    @MainActor
    static func checkCancellation() async throws {
        var delivered: [String] = []
        let task = Task { @MainActor in
            try await PaywallQueryResponse.load(bytes, configuration: .init(), catalog: catalog,
                preferredPlacement: { "c" }, onPage: { page in
                    delivered.append(page.placement)
                    withUnsafeCurrentTask { $0?.cancel() }
                })
        }
        do { _ = try await task.value; fatalError("Cancellation swallowed") }
        catch is CancellationError {}
        precondition(delivered == ["c"])
    }
}
