import Foundation

/// 真实清单与磁盘缓存集成检查，仅网络传输由内存服务器替代。
actor ResourceServer {
    var files: [URL: Data] = [:]
    var requests = 0

    func install(_ document: WebPaywallDocument, corrupt: Bool = false) throws {
        let identity = try WebPaywallPackage.identity(document)
        let base = document.pageURL.deletingLastPathComponent()
        let content = ["offline.html": "<html>offline</html>", "offline.js": "window.loaded=true;",
                       "content.json": "{}", "page.json": "{}"]
        let entries = content.sorted { $0.key < $1.key }.map { path, text in
            WebPaywallPackage.File(path: path, size: text.utf8.count,
                                   sha256: WebPaywallPackage.digest(Data(text.utf8)))
        }
        let package = WebPaywallPackage(formatVersion: 1, runtimeEnvironment: "test", document: identity,
                                        entry: "offline.html", files: entries)
        files[base.appendingPathComponent("package.json")] = try JSONEncoder().encode(package)
        for (path, text) in content { files[base.appendingPathComponent(path)] = Data(text.utf8) }
        if corrupt { files[base.appendingPathComponent("offline.js")] = Data("bad".utf8) }
    }

    func fetch(_ url: URL, _ limit: Int, _ deadline: Date) async throws -> Data {
        requests += 1
        try await Task.sleep(nanoseconds: 2_000_000)
        guard let data = files[url] else { throw URLError(.fileDoesNotExist) }
        return data
    }
    func reset() { requests = 0 }
    func count() -> Int { requests }
}

@main
struct ResourceCacheChecks {
    static func document(_ name: String, revision: Int = 1) throws -> WebPaywallDocument {
        let raw: [String: Any] = ["kind": "web-paywall", "bridgeVersion": 2, "documentId": name,
                                  "revision": revision, "pageUrl": "https://example.com/\(name)/v\(revision)/index.html",
                                  "catalogKey": "default", "productRefs": ["product"], "initialProductRef": "product"]
        return try WebPaywallDocument(data: JSONSerialization.data(withJSONObject: raw),
                                      allowedOrigins: ["https://example.com"],
                                      catalog: PaywallCatalog(productRefs: ["product"], recommendedRef: "product"))
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paywall-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = ResourceServer()
        let cache = WebPaywallResourceCache(directory: root) { try await server.fetch($0, $1, $2) }
        let a = try document("a")
        try await server.install(a)
        async let first = cache.prepare(document: a, runtimeEnvironment: "test")
        async let second = cache.prepare(document: a, runtimeEnvironment: "test")
        var leases: [WebPaywallResourceLease]? = try await [first, second]
        let count = await server.count()
        precondition(count == 5, "Concurrent downloads were not coalesced")
        await cache.clear()
        precondition(FileManager.default.fileExists(atPath: leases![0].pageURL.path))
        leases = nil
        try await Task.sleep(nanoseconds: 20_000_000)
        await server.reset()
        let restarted = WebPaywallResourceCache(directory: root) { try await server.fetch($0, $1, $2) }
        var lease: WebPaywallResourceLease? = try await restarted.prepare(document: a, runtimeEnvironment: "test")
        let hits = await server.count()
        precondition(hits == 0, "Disk hit performed network requests")
        precondition(FileManager.default.fileExists(atPath: lease!.pageURL.path))
        try await expectFailure(restarted, document: a, environment: "production")
        try await expectFailure(restarted, document: document("a", revision: 2))
        let b = try document("b")
        try await server.install(b, corrupt: true)
        try await expectFailure(restarted, document: b)
        try await server.install(b)
        var bLease: WebPaywallResourceLease? = try await restarted.prepare(document: b, runtimeEnvironment: "test")
        precondition(FileManager.default.fileExists(atPath: bLease!.pageURL.path))
        lease = nil
        bLease = nil
        try await Task.sleep(nanoseconds: 20_000_000)
        await restarted.clear()
        print("PASS Swift coalescing, disk restart, active lease protection, environment isolation, no old-version fallback, corrupt package rejection")
    }

    static func expectFailure(_ cache: WebPaywallResourceCache, document: WebPaywallDocument,
                              environment: String = "test") async throws {
        do {
            _ = try await cache.prepare(document: document, runtimeEnvironment: environment)
            fatalError("Invalid package accepted")
        } catch { }
    }
}
