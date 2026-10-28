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
                                        documents: nil, entry: "offline.html", files: entries)
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
    func manifest(_ document: WebPaywallDocument) -> Data {
        files[document.pageURL.deletingLastPathComponent().appendingPathComponent("package.json")]!
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

    /// 本次准备交接本地文档，租约保护仍生效；下一次读取必须发现后续损坏。
    static func checkPreparedLocal(root: URL, server: ResourceServer) async throws {
        let remote = try document("prepared-local")
        try await server.install(remote)
        let cache = WebPaywallResourceCache(directory: root) { try await server.fetch($0, $1, $2) }
        let (local, lease) = try await cache.prepareLocal(document: remote, environment: "test")
        precondition(local.pageURL == lease.pageURL && local.productRefs == remote.productRefs)
        await cache.clear()
        precondition(FileManager.default.fileExists(atPath: local.pageURL.path))
        try Data("corrupt".utf8).write(to: lease.readAccessURL.appendingPathComponent("offline.js"))
        do {
            _ = try await cache.prepareLocal(document: remote, environment: "test")
            fatalError("Previous handoff hid corruption")
        } catch {}
        do {
            _ = try await cache.prepareLocal(document: remote, environment: "production")
            fatalError("Wrong environment accepted")
        } catch {}
        print("PASS Swift local update handoff, active lease, next-read corruption and environment isolation")
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paywall-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = ResourceServer()
        try await checkPreparedLocal(root: root.appendingPathComponent("prepared-local"), server: server)
        await server.reset()
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
        // 冷缓存复用已取得清单，资源仍逐文件验证；错误清单在命中时也拒绝。
        let supplied = try document("supplied")
        try await server.install(supplied)
        let manifest = await server.manifest(supplied)
        await server.reset()
        let suppliedLease = try await restarted.prepare(document: supplied, runtimeEnvironment: "test", manifestData: manifest)
        let suppliedCount = await server.count()
        precondition(suppliedCount == 4, "Manifest was downloaded twice")
        do {
            _ = try await restarted.prepare(document: a, runtimeEnvironment: "test", manifestData: manifest)
            fatalError("Mismatched supplied manifest accepted")
        } catch {}
        do {
            _ = try await restarted.prepare(document: supplied, runtimeEnvironment: "production", manifestData: manifest)
            fatalError("Wrong manifest environment accepted")
        } catch {}
        precondition(FileManager.default.fileExists(atPath: suppliedLease.pageURL.path))
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
        try await checkIndependentVerification(root: root.appendingPathComponent("verification"), server: server)
        try await checkDeferredMaintenance(root: root.appendingPathComponent("maintenance"), server: server)
        try await checkFailureCleanup(root: root.appendingPathComponent("failure-cleanup"), server: server)
        print("PASS Swift coalescing, disk restart, active lease protection, environment isolation, no old-version fallback, corrupt package rejection")
    }

    /// 即使扫描被阻塞，新包仍交付；扫描后的新租约必须保护同一目录。
    static func checkDeferredMaintenance(root: URL, server: ResourceServer) async throws {
        let gate = MaintenanceGate()
        let cache = WebPaywallResourceCache(directory: root,
            scan: { await gate.scan($0, measureSize: true) },
            fetch: { try await server.fetch($0, $1, $2) })
        let doc = try document("maintenance")
        try await server.install(doc)
        var first: WebPaywallResourceLease? = try await cache.prepare(document: doc, runtimeEnvironment: "test")
        let path = first!.pageURL.path
        await gate.waitStarted()
        let clearing = Task { await cache.clear() }
        var second: WebPaywallResourceLease? = try await cache.prepare(document: doc, runtimeEnvironment: "test")
        precondition(second!.pageURL.path == path)
        first = nil
        await gate.open()
        await clearing.value
        precondition(FileManager.default.fileExists(atPath: path), "Clear deleted renewed lease")
        second = nil
        // 释放回调异步归还到 actor；随后 clear 必须等待后台删除结束。
        try await Task.sleep(nanoseconds: 20_000_000)
        let stale = root.appendingPathComponent("trash-interrupted")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: stale.appendingPathComponent("asset"))
        await cache.clear()
        precondition(!FileManager.default.fileExists(atPath: stale.path), "Interrupted cleanup was not reclaimed")
        precondition(!FileManager.default.fileExists(atPath: path), "Clear returned before idle resource removal")
        print("PASS Swift deferred prune delivery, renewed lease protection and manual clear completion")
    }

    /// 同包校验合并，不同包与 clear 不受慢包阻塞；取消单个调用者不取消共享工作。
    static func checkIndependentVerification(root: URL, server: ResourceServer) async throws {
        let slow = try document("verify-slow"), fast = try document("verify-fast")
        try await server.install(slow)
        try await server.install(fast)
        let seed = WebPaywallResourceCache(directory: root) { try await server.fetch($0, $1, $2) }
        var seeded: WebPaywallResourceLease? = try await seed.prepare(document: slow, runtimeEnvironment: "test")
        let slowDirectory = seeded!.readAccessURL
        seeded = nil
        _ = try await seed.prepare(document: fast, runtimeEnvironment: "test")
        let gate = VerificationGate(target: slowDirectory)
        let cache = WebPaywallResourceCache(directory: root,
            beforeVerify: { await gate.before($0) }, fetch: { try await server.fetch($0, $1, $2) })
        let first = Task { try await cache.prepare(document: slow, runtimeEnvironment: "test") }
        await gate.waitStarted()
        let cancelled = Task { try await cache.prepare(document: slow, runtimeEnvironment: "test") }
        let archived = Task { try await cache.cachedPackage(document: slow, environment: "test") }
        cancelled.cancel()
        let ready = try await cache.prepare(document: fast, runtimeEnvironment: "test")
        precondition(FileManager.default.fileExists(atPath: ready.pageURL.path))
        await cache.clear()
        precondition(FileManager.default.fileExists(atPath: slowDirectory.path), "Clear removed verifying package")
        let calls = await gate.count(slowDirectory)
        precondition(calls == 1, "Shared package was verified more than once concurrently")
        await gate.open()
        let firstLease = try await first.value
        let archivedLease = try await archived.value
        precondition(firstLease.readAccessURL == archivedLease.readAccessURL)
        do { _ = try await cancelled.value; fatalError("Cancelled waiter received a lease") }
        catch is CancellationError {}
        print("PASS Swift independent package verification, shared verification, cancellation and pending pin protection")
    }

    static func expectFailure(_ cache: WebPaywallResourceCache, document: WebPaywallDocument,
                              environment: String = "test") async throws {
        do {
            _ = try await cache.prepare(document: document, runtimeEnvironment: environment)
            fatalError("Invalid package accepted")
        } catch { }
    }

    /// 坏目录删除挂起时，缓存 actor 仍能交付其他包；临时目录失败不留下写入者。
    static func checkFailureCleanup(root: URL, server: ResourceServer) async throws {
        let slow = try document("cleanup-bad"), fast = try document("cleanup-fast")
        try await server.install(slow)
        try await server.install(fast)
        let seed = WebPaywallResourceCache(directory: root) { try await server.fetch($0, $1, $2) }
        var old: WebPaywallResourceLease? = try await seed.prepare(document: slow, runtimeEnvironment: "test")
        let original = old!.readAccessURL
        try Data("bad".utf8).write(to: original.appendingPathComponent("offline.js"))
        old = nil
        let gate = VerificationGate(target: root)
        let cache = WebPaywallResourceCache(directory: root,
            cleanup: { directory in
                await gate.before(root)
                return await WebPaywallCacheMaintenance.remove(directory)
            }, fetch: { try await server.fetch($0, $1, $2) })
        let repairing = Task { try await cache.prepare(document: slow, runtimeEnvironment: "test") }
        await gate.waitStarted()
        precondition(!FileManager.default.fileExists(atPath: original.path))
        let ready = try await cache.prepare(document: fast, runtimeEnvironment: "test")
        precondition(FileManager.default.fileExists(atPath: ready.pageURL.path))
        await gate.open()
        let repaired = try await repairing.value
        precondition(FileManager.default.fileExists(atPath: repaired.pageURL.path))
        print("PASS Swift quarantined corrupt-cache cleanup does not block other packages")
        let failureRoot = root.appendingPathComponent("failed-download")
        let bad = try document("cleanup-download-bad")
        try await server.install(bad, corrupt: true)
        let failureGate = VerificationGate(target: failureRoot)
        let completed = VerificationGate(target: failureRoot)
        await completed.open()
        let failing = WebPaywallResourceCache(directory: failureRoot,
            cleanup: { directory in
                precondition(directory.lastPathComponent.hasPrefix("trash-"))
                await failureGate.before(failureRoot)
                let result = await WebPaywallCacheMaintenance.remove(directory)
                await completed.before(failureRoot)
                return result
            }, fetch: { try await server.fetch($0, $1, $2) })
        try await expectFailure(failing, document: bad)
        await failureGate.waitStarted()
        let other = try await failing.prepare(document: fast, runtimeEnvironment: "test")
        precondition(FileManager.default.fileExists(atPath: other.pageURL.path))
        await failureGate.open()
        await completed.waitStarted()
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: failureRoot.path)
        precondition(!leftovers.contains { $0.hasPrefix("tmp-") || $0.hasPrefix("trash-") })
        print("PASS Swift failed-download cleanup runs after writers exit without blocking delivery")
    }
}
